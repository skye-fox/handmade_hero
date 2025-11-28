const std = @import("std");
const win = @import("std").os.windows;
const debug_mode = @import("builtin").mode == @import("std").builtin.OptimizeMode.Debug;

const handmade = @import("handmade.zig");

const zig32 = @import("zigwin32");
const audio = @import("zigwin32").media.audio;
const controller = @import("zigwin32").ui.input.xbox_controller;
const d_sound = @import("zigwin32").media.audio.direct_sound;
const foundation = @import("zigwin32").foundation;
const gdi = @import("zigwin32").graphics.gdi;
const kbam = @import("zigwin32").ui.input.keyboard_and_mouse;
const fs = @import("zigwin32").storage.file_system;
const perf = @import("zigwin32").system.performance;
const ss = @import("zigwin32").system.system_services;
const wam = @import("zigwin32").ui.windows_and_messaging;
const zig32_mem = @import("zigwin32").system.memory;
pub const UNICODE = false;

const GENERIC_READ_WRITE = fs.FILE_ACCESS_FLAGS{
    .FILE_READ_DATA = 1,
    .FILE_READ_EA = 1,
    .FILE_READ_ATTRIBUTES = 1,
    .FILE_WRITE_DATA = 1,
    .FILE_APPEND_DATA = 1,
    .FILE_WRITE_EA = 1,
    .FILE_WRITE_ATTRIBUTES = 1,
    .READ_CONTROL = 1,
    .SYNCHRONIZE = 1,
};

pub const DEBUGReadFileResult = struct {
    content_size: u32,
    content: ?*anyopaque,
};

const Win32ReplayBuffer = struct {
    file_handle: ?foundation.HANDLE,
    memory_map: ?foundation.HANDLE,
    file_name: [foundation.MAX_PATH:0]u8,
    memory_block: ?*anyopaque,
};

const Win32State = struct {
    game_memory_block: ?*anyopaque,
    total_size: usize,
    replay_buffers: [4]Win32ReplayBuffer,

    recording_handle: ?foundation.HANDLE,
    input_recording_index: u32,

    playback_handle: ?foundation.HANDLE,
    input_playing_index: u32,

    exe_file_path: [foundation.MAX_PATH:0]u8,
    one_past_last_exe_file_name_slash: ?[*:0]u8,
};

const Win32RecordedInput = struct {
    input_count: i32,
    input_stream: *handmade.GameInput,
};

const Win32GameCode = struct {
    game_code_dll: ?foundation.HINSTANCE,
    dll_last_write_time: foundation.FILETIME,

    updateAndRender: ?handmade.UpdateAndRenderFnPtr,
    getSoundSamples: ?handmade.GetSoundSamplesFnPtr,

    is_valid: bool,
};

const win32DebugTimeMarker = struct {
    output_play_cursor: win.DWORD,
    output_write_cursor: win.DWORD,
    output_location: win.DWORD,
    output_byte_count: win.DWORD,

    expected_flip_play_cursor: win.DWORD,
    flip_play_cursor: win.DWORD,
    flip_write_cursor: win.DWORD,
};

const Win32OffscreenBuffer = struct {
    info: gdi.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: usize,
    bytes_per_pixel: i32,
};

const Win32WindowDimension = struct {
    width: i32,
    height: i32,
};

const Win32SoundOutput = struct {
    samples_per_second: u32,
    bytes_per_sample: u32,
    running_sample_index: u32,
    secondary_buffer_size: u32,
    safety_bytes: u32,
};

const reserve_and_commit = zig32_mem.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 };

var instance: foundation.HINSTANCE = undefined;

var global_running = false;
var global_pause = false;
var global_back_buffer = std.mem.zeroInit(Win32OffscreenBuffer, .{});
var global_secondary_buffer: ?*d_sound.IDirectSoundBuffer8 = undefined;
var global_perf_count_frequency: i64 = 0;

inline fn rdtsc() usize {
    var a: u32 = undefined;
    var b: u32 = undefined;
    asm volatile ("rdtsc"
        : [a] "={edx}" (a),
          [b] "={eax}" (b),
    );
    return (@as(u64, a) << 32) | b;
}

// NOTE: (CASEY) Start-->
// These are NOT for doing anything in the shipping game - they are
// blocking and the write doesn't protect against lost data!

pub fn debugPlatformReadEntireFile(thread: *handmade.ThreadContext, file_path: [*:0]const u8) DEBUGReadFileResult {
    var result = DEBUGReadFileResult{
        .content_size = 0,
        .content = null,
    };

    const file_handle: foundation.HANDLE = fs.CreateFileA(file_path, fs.FILE_GENERIC_READ, fs.FILE_SHARE_READ, null, fs.OPEN_EXISTING, fs.FILE_ATTRIBUTE_NORMAL, null);
    if (file_handle != foundation.INVALID_HANDLE_VALUE) {
        var file_size: foundation.LARGE_INTEGER = undefined;
        if (zig32.zig.SUCCEEDED(fs.GetFileSizeEx(file_handle, &file_size))) {
            std.debug.assert(file_size.QuadPart <= 0xFFFFFFFF);
            const file_size32: u32 = @intCast(file_size.QuadPart);
            result.content = zig32_mem.VirtualAlloc(null, file_size32, reserve_and_commit, zig32_mem.PAGE_READWRITE);
            if (result.content) |content| {
                var bytes_read: win.DWORD = 0;
                if (zig32.zig.SUCCEEDED(fs.ReadFile(file_handle, content, file_size32, &bytes_read, null)) and file_size32 == bytes_read) {
                    std.debug.print("File read successfully.\n", .{});
                    result.content_size = file_size32;
                } else {
                    std.debug.print("Failed to read.\n", .{});
                    debugPlatformFreeFileMemory(thread, result);
                    result.content = null;
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
        zig32.zig.closeHandle(file_handle);
    } else {
        // TODO: Logging
    }
    return result;
}

pub fn debugPlatformFreeFileMemory(thread: *handmade.ThreadContext, file: DEBUGReadFileResult) void {
    _ = thread;
    if (file.content) |content| {
        _ = zig32_mem.VirtualFree(content, 0, zig32_mem.MEM_RELEASE);
    }
}

pub fn debugPlatformWriteEntireFile(thread: *handmade.ThreadContext, file_name: [*:0]const u8, memory_size: u32, memory: ?*anyopaque) bool {
    _ = thread;
    var result = false;

    const file_handle = fs.CreateFileA(file_name, fs.FILE_GENERIC_WRITE, fs.FILE_SHARE_NONE, null, fs.CREATE_ALWAYS, fs.FILE_ATTRIBUTE_NORMAL, null);
    defer zig32.zig.closeHandle(file_handle);
    if (file_handle != foundation.INVALID_HANDLE_VALUE) {
        var bytes_written: win.DWORD = 0;
        if (zig32.zig.SUCCEEDED(fs.WriteFile(file_handle, memory, memory_size, &bytes_written, null))) {
            std.debug.print("File written successfully\n", .{});
            result = bytes_written == memory_size;
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
    return result;
}

// NOTE: END-->

fn catStrings(source_A_count: usize, source_A: []const u8, source_B_count: usize, source_B: []const u8, dest_count: usize, dest: [*:0]u8) void {
    std.debug.assert(source_A_count + source_B_count <= dest_count);

    for (0..source_A_count) |i| {
        dest[i] = source_A[i];
    }
    for (0..source_B_count) |i| {
        dest[source_A_count + i] = source_B[i];
    }
    dest[source_A_count + source_B_count] = 0;
}

fn win32BuildEXEPathFileName(state: *Win32State, file_name: []const u8, dest_count: usize, dest: [*:0]u8) void {
    catStrings(
        state.one_past_last_exe_file_name_slash.? - @as([*:0]u8, @ptrCast(&state.exe_file_path)),
        &state.exe_file_path,
        file_name.len,
        file_name,
        dest_count,
        dest,
    );
}

fn win32GetEXEFileName(state: *Win32State) void {
    const size_of_file_name = zig32.system.library_loader.GetModuleFileNameA(null, &state.exe_file_path, @sizeOf(@TypeOf(state.exe_file_path)));
    state.one_past_last_exe_file_name_slash = @as([*:0]u8, @ptrCast(&state.exe_file_path));
    const scan: [*:0]u8 = @ptrCast(&state.exe_file_path);
    for (0..size_of_file_name) |i| {
        if (scan[i] == '\\') {
            state.one_past_last_exe_file_name_slash = scan + i + 1;
        }
    }
}

fn win32GetInputFileLocation(state: *Win32State, input_stream: bool, slot_index: usize, dest_count: usize, dest: [*:0]u8) !void {
    var temp: [64:0]u8 = undefined;
    const result = try std.fmt.bufPrintZ(&temp, "loop_edit_{d}_{s}.hmi", .{ slot_index, if (input_stream) "input" else "state" });
    win32BuildEXEPathFileName(state, result, dest_count, dest);
}

fn win32EndInputPlayBack(state: *Win32State) void {
    if (state.playback_handle) |playback_handle| {
        zig32.zig.closeHandle(playback_handle);
    }

    state.input_playing_index = 0;
}

fn win32BeginInputPlayBack(state: *Win32State, input_playing_index: u32) !void {
    const replay_buffer: *Win32ReplayBuffer = win32GetReplayBuffer(state, input_playing_index);

    if (replay_buffer.memory_block) |memory_block| {
        state.input_playing_index = input_playing_index;

        var file_name: [foundation.MAX_PATH:0]u8 = undefined;
        try win32GetInputFileLocation(state, true, input_playing_index, @sizeOf(@TypeOf(file_name)), &file_name);
        state.playback_handle = fs.CreateFileA(&file_name, fs.FILE_GENERIC_READ, fs.FILE_SHARE_NONE, null, fs.OPEN_EXISTING, fs.FILE_ATTRIBUTE_NORMAL, null);

        const dest = @as([*]u8, @ptrCast(state.game_memory_block))[0..state.total_size];
        const source = @as([*]u8, @ptrCast(memory_block))[0..state.total_size];
        @memcpy(dest, source);
    }
}

fn win32EndRecordingInput(state: *Win32State) void {
    if (state.recording_handle) |recording_handle| {
        zig32.zig.closeHandle(recording_handle);
    }
    state.input_recording_index = 0;
}

fn win32GetReplayBuffer(state: *Win32State, index: u32) *Win32ReplayBuffer {
    std.debug.assert(index < state.replay_buffers.len);
    const result: *Win32ReplayBuffer = &state.replay_buffers[index];
    return result;
}

fn win32BeginRecordingInput(state: *Win32State, input_recording_index: u32) !void {
    const replay_buffer: *Win32ReplayBuffer = win32GetReplayBuffer(state, input_recording_index);
    if (replay_buffer.memory_block) |memory_block| {
        state.input_recording_index = input_recording_index;

        var file_name: [foundation.MAX_PATH:0]u8 = undefined;
        try win32GetInputFileLocation(state, true, input_recording_index, @sizeOf(@TypeOf(file_name)), &file_name);
        state.recording_handle = fs.CreateFileA(&file_name, fs.FILE_GENERIC_WRITE, fs.FILE_SHARE_NONE, null, fs.CREATE_ALWAYS, fs.FILE_ATTRIBUTE_NORMAL, null);

        const dest = @as([*]u8, @ptrCast(memory_block))[0..state.total_size];
        const source = @as([*]u8, @ptrCast(state.game_memory_block))[0..state.total_size];
        @memcpy(dest, source);
    }
}

fn win32RecordInput(state: *Win32State, new_input: *handmade.GameInput) void {
    var bytes_written: win.DWORD = 0;
    _ = fs.WriteFile(state.recording_handle, new_input, @sizeOf(handmade.GameInput), &bytes_written, null);
}

fn win32PlayBackInput(state: *Win32State, new_input: *handmade.GameInput) !void {
    var bytes_read: win.DWORD = 0;
    if (zig32.zig.SUCCEEDED(fs.ReadFile(state.playback_handle, new_input, @sizeOf(handmade.GameInput), &bytes_read, null))) {
        if (bytes_read == 0) {
            const playing_index = state.input_playing_index;
            win32EndInputPlayBack(state);
            try win32BeginInputPlayBack(state, playing_index);
        }
    }
}

fn win32GetLastWriteTime(file_name: ?[*:0]const u8) foundation.FILETIME {
    var last_write_time = std.mem.zeroInit(foundation.FILETIME, .{});

    var data: fs.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (fs.GetFileAttributesExA(file_name, fs.GetFileExInfoStandard, &data) != 0) {
        last_write_time = data.ftLastWriteTime;
    }

    return last_write_time;
}

fn win32UnloadGameCode(game_code: *Win32GameCode) void {
    if (game_code.game_code_dll != null) {
        _ = zig32.system.library_loader.FreeLibrary(game_code.game_code_dll);
        game_code.game_code_dll = null;
    }

    game_code.is_valid = false;
    game_code.updateAndRender = null;
    game_code.getSoundSamples = null;
}

fn win32LoadGameCode(source_dll_name: ?[*:0]const u8, temp_dll_name: []const u8) Win32GameCode {
    var result = std.mem.zeroInit(Win32GameCode, .{});

    result.dll_last_write_time = win32GetLastWriteTime(source_dll_name);
    _ = fs.CopyFileA(@ptrCast(source_dll_name), @ptrCast(temp_dll_name), 0);

    result.game_code_dll = zig32.system.library_loader.LoadLibraryA(@ptrCast(temp_dll_name));
    if (result.game_code_dll != null) {
        result.updateAndRender = @ptrCast(zig32.system.library_loader.GetProcAddress(result.game_code_dll, "gameUpdateAndRender"));
        result.getSoundSamples = @ptrCast(zig32.system.library_loader.GetProcAddress(result.game_code_dll, "getSoundSamples"));

        result.is_valid = (result.updateAndRender != null and result.getSoundSamples != null);

        if (!result.is_valid) {
            result.updateAndRender = null;
            result.getSoundSamples = null;
        }
    }

    return result;
}

inline fn win32GetWallClock() foundation.LARGE_INTEGER {
    var result: foundation.LARGE_INTEGER = undefined;
    _ = perf.QueryPerformanceCounter(&result);
    return result;
}

inline fn win32GetSecondsElapsed(start: foundation.LARGE_INTEGER, end: foundation.LARGE_INTEGER) f32 {
    const result: f32 = @as(f32, @floatFromInt(end.QuadPart - start.QuadPart)) / @as(f32, @floatFromInt(global_perf_count_frequency));
    return result;
}

inline fn win32DrawSoundBufferMarker(back_buffer: *Win32OffscreenBuffer, c: f32, pad_x: u32, top: u32, bottom: u32, value: win.DWORD, color: u32) void {
    const x_f32: f32 = c * @as(f32, @floatFromInt(value));
    const x: u32 = pad_x + @as(u32, @intFromFloat(x_f32));
    win32DebugDrawVertical(back_buffer, x, top, bottom, color);
}

fn win32DebugDrawVertical(back_buffer: *Win32OffscreenBuffer, x: u32, top: u32, bottom: u32, color: u32) void {
    var this_top: u32 = top;
    var this_bottom: u32 = bottom;
    if (this_top <= 0) this_top = 0;
    if (this_bottom > back_buffer.height) this_bottom = @intCast(back_buffer.height);

    if (x >= 0 and x < back_buffer.width) {
        var pixel: [*]u8 = @as([*]u8, @ptrCast(back_buffer.memory)) + x * @as(u32, @intCast(back_buffer.bytes_per_pixel)) + this_top * @as(u32, @intCast(back_buffer.pitch));
        for (this_top..this_bottom) |_| {
            @as([*]u32, @ptrCast(@alignCast(pixel)))[0] = color;
            pixel += @as(u32, @intCast(back_buffer.pitch));
        }
    }
}

fn win32DebugSyncDisplay(back_buffer: *Win32OffscreenBuffer, sound_output: *Win32SoundOutput, markers: []win32DebugTimeMarker, marker_count: u32, current_marker_index: win.DWORD) void {
    const pad_x: u32 = 16;
    const pad_y: u32 = 16;

    const line_height: u32 = 64;

    const c: f32 = @as(f32, @floatFromInt(back_buffer.width - 2 * pad_x)) / @as(f32, @floatFromInt(sound_output.secondary_buffer_size));
    for (0..marker_count) |index| {
        const this_marker: *win32DebugTimeMarker = &markers[index];
        std.debug.assert(this_marker.output_play_cursor < sound_output.secondary_buffer_size);
        std.debug.assert(this_marker.output_write_cursor < sound_output.secondary_buffer_size);
        std.debug.assert(this_marker.output_location < sound_output.secondary_buffer_size);
        std.debug.assert(this_marker.output_byte_count < sound_output.secondary_buffer_size);
        std.debug.assert(this_marker.flip_play_cursor < sound_output.secondary_buffer_size);
        std.debug.assert(this_marker.flip_write_cursor < sound_output.secondary_buffer_size);

        const play_color: u32 = 0xFFFFFFFF;
        const write_color: u32 = 0xFFFF0000;
        const expected_flip_color: u32 = 0xFFFFFF00;
        const play_window_color: u32 = 0xFFFF00FF;

        var top = pad_y;
        var bottom: u32 = pad_y + line_height;
        if (index == current_marker_index) {
            top += line_height + pad_y;
            bottom += line_height + pad_y;

            const first_top: u32 = top;

            win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.output_play_cursor, play_color);
            win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.output_write_cursor, write_color);

            top += line_height + pad_y;
            bottom += line_height + pad_y;

            win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.output_location, play_color);
            win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.output_location + this_marker.output_byte_count, write_color);

            top += line_height + pad_y;
            bottom += line_height + pad_y;

            win32DrawSoundBufferMarker(back_buffer, c, pad_x, first_top, bottom, this_marker.expected_flip_play_cursor, expected_flip_color);
        }

        win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.flip_play_cursor, play_color);
        win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.flip_play_cursor + 480 * sound_output.bytes_per_sample, play_window_color);
        win32DrawSoundBufferMarker(back_buffer, c, pad_x, top, bottom, this_marker.flip_write_cursor, write_color);
    }
}

fn win32ProcessPendingMessages(state: *Win32State, keyboard_controller: *handmade.GameControllerInput) !void {
    var message: wam.MSG = undefined;
    while (wam.PeekMessageA(&message, null, 0, 0, wam.PM_REMOVE) != 0) {
        switch (message.message) {
            wam.WM_QUIT => global_running = false,
            wam.WM_SYSKEYDOWN, wam.WM_SYSKEYUP, wam.WM_KEYDOWN, wam.WM_KEYUP => {
                // const vk_int = message.wParam;
                const was_down: bool = ((message.lParam & (1 << 30)) != 0);
                const is_down: bool = ((message.lParam & (1 << 31)) == 0);

                if (was_down != is_down) {
                    const vk_code = std.meta.intToEnum(kbam.VIRTUAL_KEY, message.wParam) catch {
                        continue;
                    };
                    switch (vk_code) {
                        .W => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_up, is_down),
                        .A => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_left, is_down),
                        .S => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_down, is_down),
                        .D => win32ProcessKeyboardMessage(&keyboard_controller.button.input.move_right, is_down),
                        .Q => win32ProcessKeyboardMessage(&keyboard_controller.button.input.left_shoulder, is_down),
                        .E => win32ProcessKeyboardMessage(&keyboard_controller.button.input.right_shoulder, is_down),
                        .UP => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_up, is_down),
                        .LEFT => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_left, is_down),
                        .DOWN => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_down, is_down),
                        .RIGHT => win32ProcessKeyboardMessage(&keyboard_controller.button.input.action_right, is_down),
                        .SPACE => {},
                        .F4 => {
                            const alt_down: bool = ((message.lParam & (1 << 29)) != 0);
                            if (alt_down) {
                                global_running = false;
                            }
                        },
                        .ESCAPE => {
                            win32ProcessKeyboardMessage(&keyboard_controller.button.input.back, is_down);
                            if (debug_mode and is_down) {
                                global_running = false;
                            }
                        },
                        .L => {
                            if (is_down) {
                                if (state.input_playing_index == 0) {
                                    if (state.input_recording_index == 0) {
                                        try win32BeginRecordingInput(state, 1);
                                    } else {
                                        win32EndRecordingInput(state);
                                        try win32BeginInputPlayBack(state, 1);
                                    }
                                } else {
                                    win32EndInputPlayBack(state);
                                }
                            }
                        },
                        .P => {
                            if (debug_mode) {
                                if (is_down) global_pause = !global_pause;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {
                _ = wam.TranslateMessage(&message);
                _ = wam.DispatchMessageA(&message);
            },
        }
    }
}

fn win32ProcessKeyboardMessage(new_state: *handmade.GameButtonState, is_down: bool) void {
    if (new_state.ended_down != is_down) {
        new_state.ended_down = is_down;
        new_state.half_transition_count += 1;
    }
}

fn win32ProcessXInputStickValue(value: win.SHORT, deadzone_threshold: win.SHORT) f32 {
    var result: f32 = 0.0;

    if (value < -deadzone_threshold) {
        result = @as(f32, @floatFromInt(@as(i32, value) + @as(i32, deadzone_threshold))) / (32768.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    } else if (value > deadzone_threshold) {
        result = @as(f32, @floatFromInt(@as(i32, value) - @as(i32, deadzone_threshold))) / (32767.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    }
    return result;
}

fn win32ProcessXInputDigitalButton(old_state: *handmade.GameButtonState, new_state: *handmade.GameButtonState, xinput_button_state: win.DWORD, button_bit: win.DWORD) void {
    new_state.ended_down = if ((xinput_button_state & button_bit) == button_bit) true else false;
    new_state.half_transition_count = if (old_state.ended_down != new_state.ended_down) 1 else 0;
}

fn win32ClearBuffer(sound_output: *Win32SoundOutput) void {
    var region_one: ?*anyopaque = null;
    var region_one_size: win.DWORD = 0;
    var region_two: ?*anyopaque = null;
    var region_two_size: win.DWORD = 0;
    if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(0, sound_output.secondary_buffer_size, &region_one, &region_one_size, &region_two, &region_two_size, 0))) {
        var dest_sample: [*]u8 = @ptrCast(@alignCast(region_one));
        for (0..region_one_size) |_| {
            dest_sample[0] = 0;
            dest_sample += 1;
        }
        if (region_two) |_| {
            dest_sample = @ptrCast(@alignCast(region_two));
            for (0..region_two_size) |_| {
                dest_sample[0] = 0;
                dest_sample += 1;
            }
        }
        _ = global_secondary_buffer.?.IDirectSoundBuffer.Unlock(region_one, region_one_size, region_two, region_two_size);
    }
}

fn win32FillSoundBuffer(sound_output: *Win32SoundOutput, source_buffer: *handmade.GameSoundOutputBuffer, byte_to_lock: win.DWORD, bytes_to_write: win.DWORD) void {
    var region_one: ?*anyopaque = null;
    var region_one_size: win.DWORD = 0;
    var region_two: ?*anyopaque = null;
    var region_two_size: win.DWORD = 0;

    if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.Lock(byte_to_lock, bytes_to_write, &region_one, &region_one_size, &region_two, &region_two_size, 0))) {
        const region_one_sample_count = region_one_size / sound_output.bytes_per_sample;

        var dest_sample: [*]i16 = @ptrCast(@alignCast(region_one));
        var source_sample: [*]i16 = source_buffer.samples;
        for (0..region_one_sample_count) |_| {
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;

            sound_output.running_sample_index += 1;
        }

        if (region_two) |_| {
            const region_two_sample_count = region_two_size / sound_output.bytes_per_sample;
            dest_sample = @ptrCast(@alignCast(region_two));
            for (0..region_two_sample_count) |_| {
                dest_sample[0] = source_sample[0];
                dest_sample += 1;
                source_sample += 1;
                dest_sample[0] = source_sample[0];
                dest_sample += 1;
                source_sample += 1;

                sound_output.running_sample_index += 1;
            }
        }
        _ = global_secondary_buffer.?.IDirectSoundBuffer.Unlock(region_one, region_one_size, region_two, region_two_size);
    }
}

fn win32InitDSound(window: foundation.HWND, samples_per_second: u32, buffer_size: u32) void {
    var direct_sound: ?*d_sound.IDirectSound8 = undefined;
    if (zig32.zig.SUCCEEDED(d_sound.DirectSoundCreate8(null, &direct_sound, null))) {
        var wave_format = std.mem.zeroInit(audio.WAVEFORMATEX, .{});
        wave_format.wFormatTag = audio.WAVE_FORMAT_PCM;
        wave_format.nChannels = 2;
        wave_format.nSamplesPerSec = samples_per_second;
        wave_format.wBitsPerSample = 16;
        wave_format.nBlockAlign = (wave_format.nChannels * wave_format.wBitsPerSample) / 8;
        wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * wave_format.nBlockAlign;

        if (zig32.zig.SUCCEEDED(direct_sound.?.IDirectSound.SetCooperativeLevel(window, d_sound.DSSCL_PRIORITY))) {
            var buffer_description = std.mem.zeroInit(d_sound.DSBUFFERDESC, .{});
            buffer_description.dwSize = @sizeOf(@TypeOf(buffer_description));
            buffer_description.dwFlags = d_sound.DSBCAPS_PRIMARYBUFFER;

            var primary_buffer: ?*d_sound.IDirectSoundBuffer8 = undefined;
            if (zig32.zig.SUCCEEDED(direct_sound.?.IDirectSound.CreateSoundBuffer(&buffer_description, &primary_buffer, null))) {
                if (zig32.zig.SUCCEEDED(primary_buffer.?.IDirectSoundBuffer.SetFormat(&wave_format))) {
                    // We have finally set the format
                    std.debug.print("Primary buffer was set.\n", .{});
                } else {
                    // TODO: Logging
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
        var buffer_description = std.mem.zeroInit(d_sound.DSBUFFERDESC, .{});
        buffer_description.dwSize = @sizeOf(@TypeOf(buffer_description));
        buffer_description.dwBufferBytes = buffer_size;
        buffer_description.lpwfxFormat = &wave_format;

        if (zig32.zig.SUCCEEDED(direct_sound.?.IDirectSound.CreateSoundBuffer(&buffer_description, &global_secondary_buffer, null))) {
            std.debug.print("Secondary buffer created successfully.\n", .{});
            if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.SetFormat(&wave_format))) {
                // We have finally set the format
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }
    } else {
        // TODO: Logging
    }
}

fn win32GetWindowDimension(window: foundation.HWND) Win32WindowDimension {
    var client_rect: foundation.RECT = undefined;
    _ = wam.GetClientRect(window, &client_rect);

    const result = Win32WindowDimension{
        .width = client_rect.right - client_rect.left,
        .height = client_rect.bottom - client_rect.top,
    };
    return result;
}

fn win32ResizeDIBSection(buffer: *Win32OffscreenBuffer, width: i32, height: i32) void {
    if (buffer.memory) |memory| {
        _ = zig32_mem.VirtualFree(memory, 0, zig32_mem.MEM_RELEASE);
    }

    buffer.width = width;
    buffer.height = height;

    buffer.info.bmiHeader.biSize = @sizeOf(@TypeOf(buffer.info.bmiHeader));
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height;
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = gdi.BI_RGB;

    buffer.bytes_per_pixel = 4;

    const bitmap_memory_size = (buffer.width * buffer.height) * buffer.bytes_per_pixel;
    buffer.memory = zig32_mem.VirtualAlloc(null, @as(usize, @intCast(bitmap_memory_size)), reserve_and_commit, zig32_mem.PAGE_READWRITE);

    buffer.pitch = @as(usize, @intCast(buffer.width)) * @as(usize, @intCast(buffer.bytes_per_pixel));
}

fn win32DisplayBufferInWindow(buffer: *Win32OffscreenBuffer, device_context: gdi.HDC, window_width: i32, window_height: i32) void {
    _ = window_width;
    _ = window_height;
    _ = gdi.StretchDIBits(device_context, 0, 0, buffer.width, buffer.height, 0, 0, buffer.width, buffer.height, buffer.memory, &buffer.info, gdi.DIB_RGB_COLORS, gdi.SRCCOPY);
}

fn win32MainWindowCallback(window: foundation.HWND, message: win.UINT, wparam: foundation.WPARAM, lparam: foundation.LPARAM) callconv(.c) foundation.LRESULT {
    var result: foundation.LRESULT = 0;
    switch (message) {
        wam.WM_ACTIVATEAPP => {
            std.debug.print("WM_ACTIVATEAPP\n", .{});
        },
        wam.WM_CLOSE, wam.WM_DESTROY => global_running = false,
        wam.WM_KEYDOWN, wam.WM_KEYUP, wam.WM_SYSKEYDOWN, wam.WM_SYSKEYUP => {
            unreachable;
        },
        wam.WM_PAINT => {
            var paint: gdi.PAINTSTRUCT = undefined;
            const device_context = gdi.BeginPaint(window, &paint);

            const dimension = win32GetWindowDimension(window);

            win32DisplayBufferInWindow(&global_back_buffer, device_context.?, dimension.width, dimension.height);
            _ = gdi.EndPaint(window, &paint);
        },
        else => {
            result = wam.DefWindowProcA(window, message, wparam, lparam);
        },
    }
    return result;
}

pub fn run() !void {
    var state = std.mem.zeroes(Win32State);

    var perf_count_frequency_result: foundation.LARGE_INTEGER = undefined;
    _ = perf.QueryPerformanceFrequency(&perf_count_frequency_result);
    global_perf_count_frequency = perf_count_frequency_result.QuadPart;

    win32GetEXEFileName(&state);
    var source_game_code_dll_full_path: [foundation.MAX_PATH:0]u8 = undefined;
    win32BuildEXEPathFileName(&state, "handmade_hero.dll", @sizeOf(@TypeOf(source_game_code_dll_full_path)), &source_game_code_dll_full_path);

    var temp_game_code_dll_full_path: [foundation.MAX_PATH:0]u8 = undefined;
    win32BuildEXEPathFileName(&state, "handmade_temp.dll", @sizeOf(@TypeOf(temp_game_code_dll_full_path)), &temp_game_code_dll_full_path);

    // NOTE:(Casey): Set the windows scheduler granularity to 1ms.
    const desired_scheduler_ms = 1;
    const sleep_is_granular: bool = zig32.media.timeBeginPeriod(desired_scheduler_ms) == zig32.everything.TIMERR_NOERROR;

    win32ResizeDIBSection(&global_back_buffer, 1280, 720);

    var window_class = std.mem.zeroInit(wam.WNDCLASSA, .{});

    window_class.style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 };
    window_class.lpfnWndProc = win32MainWindowCallback;
    window_class.hInstance = instance;
    window_class.lpszClassName = "Handmade Hero";

    if (wam.RegisterClassA(&window_class) != 0) {
        const window_handle = wam.CreateWindowExA(
            wam.WINDOW_EX_STYLE{},
            window_class.lpszClassName,
            "Handmade Hero",
            wam.WINDOW_STYLE{ .BORDER = 1, .DLGFRAME = 1, .GROUP = 1, .SYSMENU = 1, .TABSTOP = 1, .THICKFRAME = 1, .VISIBLE = 1 },
            wam.CW_USEDEFAULT,
            wam.CW_USEDEFAULT,
            wam.CW_USEDEFAULT,
            wam.CW_USEDEFAULT,
            null,
            null,
            instance,
            null,
        );

        if (window_handle) |window| {
            const device_context = gdi.GetDC(window);

            var monitor_refresh_hz: f32 = 60.0;
            const win32_refresh_rate: f32 = @floatFromInt(gdi.GetDeviceCaps(device_context, gdi.VREFRESH));
            if (win32_refresh_rate > 1) {
                monitor_refresh_hz = win32_refresh_rate;
            }

            const game_update_hz: f32 = monitor_refresh_hz / 2.0;
            const target_seconds_per_frame: f32 = 1.0 / game_update_hz;

            var sound_output = std.mem.zeroInit(Win32SoundOutput, .{
                .samples_per_second = 48000,
                .bytes_per_sample = @sizeOf(i16) * 2,
            });
            sound_output.secondary_buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample;
            const safety_seconds: f32 = 0.025;
            sound_output.safety_bytes = @intFromFloat(((@as(f32, @floatFromInt(sound_output.samples_per_second)) * @as(f32, @floatFromInt(sound_output.bytes_per_sample))) / game_update_hz) / safety_seconds);

            win32InitDSound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32ClearBuffer(&sound_output);
            _ = global_secondary_buffer.?.IDirectSoundBuffer.Play(0, 0, d_sound.DSBPLAY_LOOPING);

            const samples: ?[*]i16 = @ptrCast(@alignCast(zig32_mem.VirtualAlloc(null, sound_output.secondary_buffer_size, reserve_and_commit, zig32_mem.PAGE_READWRITE)));

            const base_address: ?*anyopaque = if (debug_mode) @ptrFromInt(handmade.teraBytes(2)) else null;

            var game_memory = handmade.GameMemory{
                .is_initialized = false,
                .permanent_storage_size = 0,
                .permanent_storage = null,
                .transient_storage_size = 0,
                .transient_storage = null,

                .debugPlatformReadEntireFile = debugPlatformReadEntireFile,
                .debugPlatformFreeFileMemory = debugPlatformFreeFileMemory,
                .debugPlatformWriteEntireFile = debugPlatformWriteEntireFile,
            };
            game_memory.permanent_storage_size = handmade.megaBytes(64);
            game_memory.transient_storage_size = handmade.gigaBytes(1);

            state.total_size = game_memory.permanent_storage_size + game_memory.transient_storage_size;
            state.game_memory_block = @ptrCast(@alignCast(zig32_mem.VirtualAlloc(base_address, state.total_size, reserve_and_commit, zig32_mem.PAGE_READWRITE)));
            game_memory.permanent_storage = state.game_memory_block;
            game_memory.transient_storage = @as([*]u8, @ptrCast(game_memory.permanent_storage)) + game_memory.permanent_storage_size;

            for (0..state.replay_buffers.len) |replay_index| {
                const replay_buffer: *Win32ReplayBuffer = &state.replay_buffers[replay_index];

                try win32GetInputFileLocation(&state, false, replay_index, @sizeOf(@TypeOf(replay_buffer.file_name)), &replay_buffer.file_name);
                replay_buffer.file_handle = fs.CreateFileA(&replay_buffer.file_name, GENERIC_READ_WRITE, fs.FILE_SHARE_NONE, null, fs.CREATE_ALWAYS, fs.FILE_ATTRIBUTE_NORMAL, null);

                var max_size: foundation.LARGE_INTEGER = undefined;
                max_size.QuadPart = @intCast(state.total_size);
                replay_buffer.memory_map = zig32_mem.CreateFileMappingA(replay_buffer.file_handle, null, zig32_mem.PAGE_READWRITE, @intCast(max_size.u.HighPart), max_size.u.LowPart, null);

                replay_buffer.memory_block = zig32_mem.MapViewOfFile(replay_buffer.memory_map, zig32_mem.FILE_MAP_ALL_ACCESS, 0, 0, state.total_size);
                if (replay_buffer.memory_block != null) {
                    // got memory
                } else {

                    // TODO: Logging
                }
            }

            if (samples != null and game_memory.permanent_storage != null and game_memory.transient_storage != null) {
                var input = [_]handmade.GameInput{std.mem.zeroInit(handmade.GameInput, .{})} ** 2;
                var new_input: *handmade.GameInput = &input[0];
                var old_input: *handmade.GameInput = &input[1];

                var last_counter: foundation.LARGE_INTEGER = win32GetWallClock();
                var flip_wall_clock: foundation.LARGE_INTEGER = win32GetWallClock();

                var debug_time_markers = [_]win32DebugTimeMarker{std.mem.zeroInit(win32DebugTimeMarker, .{})} ** 30;
                var debug_time_marker_index: u32 = 0;

                var audio_latency_bytes: win.DWORD = 0;
                var audio_latency_seconds: f32 = 0.0;
                var sound_is_valid = false;

                var last_cycle_count: i64 = @intCast(rdtsc());

                var game: Win32GameCode = win32LoadGameCode(&source_game_code_dll_full_path, &temp_game_code_dll_full_path);
                global_running = true;
                while (global_running) {
                    new_input.dt_for_frame = target_seconds_per_frame;

                    const new_dll_write_time: foundation.FILETIME = win32GetLastWriteTime(&source_game_code_dll_full_path);
                    if (fs.CompareFileTime(&new_dll_write_time, &game.dll_last_write_time) != 0) {
                        win32UnloadGameCode(&game);
                        game = win32LoadGameCode(&source_game_code_dll_full_path, &temp_game_code_dll_full_path);
                    }

                    const old_keyboard_controller: *handmade.GameControllerInput = handmade.getController(old_input, 0);
                    const new_keyboard_controller: *handmade.GameControllerInput = handmade.getController(new_input, 0);
                    new_keyboard_controller.is_connected = true;

                    for (0..new_keyboard_controller.button.buttons.len) |button_index| {
                        new_keyboard_controller.button.buttons[button_index].ended_down = old_keyboard_controller.button.buttons[button_index].ended_down;
                    }

                    try win32ProcessPendingMessages(&state, new_keyboard_controller);

                    if (!global_pause) {
                        var mouse_pos: foundation.POINT = undefined;
                        _ = wam.GetCursorPos(&mouse_pos);
                        _ = gdi.ScreenToClient(window, &mouse_pos);
                        new_input.mouse_x = mouse_pos.x;
                        new_input.mouse_y = mouse_pos.y;
                        new_input.mouse_z = 0;

                        win32ProcessKeyboardMessage(&new_input.mouse_buttons[0], (@as(i32, kbam.GetKeyState(@intFromEnum(kbam.VK_LBUTTON))) & (1 << 15) != 0));
                        win32ProcessKeyboardMessage(&new_input.mouse_buttons[1], (@as(i32, kbam.GetKeyState(@intFromEnum(kbam.VK_MBUTTON))) & (1 << 15) != 0));
                        win32ProcessKeyboardMessage(&new_input.mouse_buttons[2], (@as(i32, kbam.GetKeyState(@intFromEnum(kbam.VK_RBUTTON))) & (1 << 15) != 0));
                        win32ProcessKeyboardMessage(&new_input.mouse_buttons[3], (@as(i32, kbam.GetKeyState(@intFromEnum(kbam.VK_XBUTTON1))) & (1 << 15) != 0));
                        win32ProcessKeyboardMessage(&new_input.mouse_buttons[4], (@as(i32, kbam.GetKeyState(@intFromEnum(kbam.VK_XBUTTON2))) & (1 << 15) != 0));

                        var max_controller_count = controller.XUSER_MAX_COUNT;
                        if (max_controller_count > new_input.controllers.len - 1) {
                            max_controller_count = new_input.controllers.len - 1;
                        }

                        for (0..max_controller_count) |controller_index| {
                            const our_controller_index = controller_index + 1;
                            const old_controller: *handmade.GameControllerInput = handmade.getController(old_input, our_controller_index);
                            const new_controller: *handmade.GameControllerInput = handmade.getController(new_input, our_controller_index);

                            var controller_state = std.mem.zeroInit(controller.XINPUT_STATE, .{});

                            if (controller.XInputGetState(@intCast(controller_index), &controller_state) == @intFromEnum(foundation.ERROR_SUCCESS)) {
                                new_controller.is_connected = true;
                                new_controller.is_analog = old_controller.is_analog;
                                // Controller available
                                const pad = &controller_state.Gamepad;

                                new_controller.left_stick_average_x = win32ProcessXInputStickValue(pad.sThumbLX, controller.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);
                                new_controller.left_stick_average_y = win32ProcessXInputStickValue(pad.sThumbLY, controller.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);

                                new_controller.right_stick_average_x = win32ProcessXInputStickValue(pad.sThumbRX, controller.XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE);
                                new_controller.right_stick_average_y = win32ProcessXInputStickValue(pad.sThumbRY, controller.XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE);

                                if (new_controller.left_stick_average_x != 0.0 or new_controller.left_stick_average_y != 0.0) {
                                    new_controller.is_analog = true;
                                }

                                if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_UP) != 0) {
                                    new_controller.left_stick_average_y = 1.0;
                                    new_controller.is_analog = false;
                                }

                                if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_DOWN) != 0) {
                                    new_controller.left_stick_average_y = -1.0;
                                    new_controller.is_analog = false;
                                }

                                if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_LEFT) != 0) {
                                    new_controller.left_stick_average_x = -1.0;
                                    new_controller.is_analog = false;
                                }

                                if ((pad.wButtons & controller.XINPUT_GAMEPAD_DPAD_RIGHT) != 0) {
                                    new_controller.left_stick_average_x = 1.0;
                                    new_controller.is_analog = false;
                                }

                                // const threshold: f32 = 0.5;
                                //
                                // win32ProcessXInputDigitalButton(
                                //     &old_controller.button.input.move_up,
                                //     &new_controller.button.input.move_up,
                                //     if (new_controller.left_stick_average_y < threshold) 1 else 0,
                                //     1,
                                // );
                                //
                                // win32ProcessXInputDigitalButton(
                                //     &old_controller.button.input.move_down,
                                //     &new_controller.button.input.move_down,
                                //     if (new_controller.left_stick_average_y < -threshold) 1 else 0,
                                //     1,
                                // );
                                //
                                // win32ProcessXInputDigitalButton(
                                //     &old_controller.button.input.move_left,
                                //     &new_controller.button.input.move_left,
                                //     if (new_controller.left_stick_average_x < -threshold) 1 else 0,
                                //     1,
                                // );
                                //
                                // win32ProcessXInputDigitalButton(
                                //     &old_controller.button.input.move_right,
                                //     &new_controller.button.input.move_right,
                                //     if (new_controller.left_stick_average_x < threshold) 1 else 0,
                                //     1,
                                // );

                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.move_up,
                                    &new_controller.button.input.move_up,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_DPAD_UP,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.move_down,
                                    &new_controller.button.input.move_down,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_DPAD_DOWN,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.move_left,
                                    &new_controller.button.input.move_left,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_DPAD_LEFT,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.move_right,
                                    &new_controller.button.input.move_right,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_DPAD_RIGHT,
                                );

                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.action_down,
                                    &new_controller.button.input.action_down,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_A,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.action_right,
                                    &new_controller.button.input.action_right,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_B,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.action_left,
                                    &new_controller.button.input.action_left,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_X,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.action_up,
                                    &new_controller.button.input.action_up,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_Y,
                                );

                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.start,
                                    &new_controller.button.input.start,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_START,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.back,
                                    &new_controller.button.input.back,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_BACK,
                                );

                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.left_shoulder,
                                    &new_controller.button.input.left_shoulder,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_LEFT_SHOULDER,
                                );
                                win32ProcessXInputDigitalButton(
                                    &old_controller.button.input.right_shoulder,
                                    &new_controller.button.input.right_shoulder,
                                    pad.wButtons,
                                    controller.XINPUT_GAMEPAD_RIGHT_SHOULDER,
                                );
                            } else {
                                // Controller not available
                                new_controller.is_connected = false;
                            }
                        }

                        var thread = std.mem.zeroInit(handmade.ThreadContext, .{});

                        var buffer = handmade.GameOffScreenBuffer{
                            .memory = @ptrCast(@alignCast(global_back_buffer.memory)),
                            .width = global_back_buffer.width,
                            .height = global_back_buffer.height,
                            .pitch = global_back_buffer.pitch,
                            .bytes_per_pixel = global_back_buffer.bytes_per_pixel,
                        };

                        if (state.input_recording_index != 0) {
                            win32RecordInput(&state, new_input);
                        }
                        if (state.input_playing_index != 0) {
                            try win32PlayBackInput(&state, new_input);
                        }

                        if (game.updateAndRender) |updateAndRender| updateAndRender(&thread, &game_memory, new_input, &buffer);

                        const audio_wall_clock: foundation.LARGE_INTEGER = win32GetWallClock();
                        const from_begin_to_audio_seconds: f32 = win32GetSecondsElapsed(flip_wall_clock, audio_wall_clock);

                        var write_cursor: win.DWORD = 0;
                        var play_cursor: win.DWORD = 0;
                        if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor))) {

                            // NOTE: (Casey): Here is how sound output computation works.
                            //
                            // We define a safety value that is the number of samples we think our game update loop may vary
                            // by (let's say up to 2ms)
                            //
                            // When we wake up to write audio, we will look and see what the play cursor position is
                            // and we will forecast ahead where we think the play cursor will be on the next frame boundary.
                            //
                            // We will then look to see if the write cursor is before that by at least our safety value. If
                            // it is, the target fill position is that frame boundary plus one frame. This gives us perfect
                            // audio sync in the case of a card that has low enough latency
                            //
                            // If the write cursor is after that safety margin, then we assume we can never sync the
                            // audio perfectly, so we will write one frame's worth of audio plus the safety margin's worth of guard samples.

                            if (!sound_is_valid) {
                                sound_output.running_sample_index = write_cursor / sound_output.bytes_per_sample;
                                sound_is_valid = true;
                            }

                            const byte_to_lock: win.DWORD = (sound_output.running_sample_index * sound_output.bytes_per_sample) % sound_output.secondary_buffer_size;

                            // const expected_sound_bytes_per_frame_real: f32 = (@as(f32, @floatFromInt(sound_output.samples_per_second)) * @as(f32, @floatFromInt(sound_output.bytes_per_sample))) / game_update_hz;

                            const expected_sound_bytes_per_frame: u32 = @intFromFloat(@as(f32, @floatFromInt(sound_output.samples_per_second * sound_output.bytes_per_sample)) / game_update_hz);
                            const seconds_left_until_flip = target_seconds_per_frame - from_begin_to_audio_seconds;
                            var expected_bytes_until_flip: u32 = 0;
                            if (seconds_left_until_flip > 0) {
                                expected_bytes_until_flip = @intFromFloat((seconds_left_until_flip / target_seconds_per_frame) * @as(f32, @floatFromInt(expected_sound_bytes_per_frame)));
                            } else {
                                expected_bytes_until_flip = 0;
                            }
                            const expected_frame_boundary_byte: win.DWORD = play_cursor + expected_bytes_until_flip;

                            var safe_write_cursor: win.DWORD = write_cursor;
                            if (safe_write_cursor < play_cursor) {
                                safe_write_cursor += sound_output.secondary_buffer_size;
                            }
                            std.debug.assert(safe_write_cursor >= play_cursor);
                            safe_write_cursor += sound_output.safety_bytes;

                            const audio_card_is_low_latency: bool = (safe_write_cursor < expected_frame_boundary_byte);

                            var target_cursor: win.DWORD = 0;
                            if (audio_card_is_low_latency) {
                                target_cursor = ((expected_frame_boundary_byte + expected_sound_bytes_per_frame));
                            } else {
                                target_cursor = write_cursor + expected_sound_bytes_per_frame + sound_output.safety_bytes;
                            }
                            target_cursor = target_cursor % sound_output.secondary_buffer_size;

                            var bytes_to_write: win.DWORD = 0;
                            if (byte_to_lock > target_cursor) {
                                bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                                bytes_to_write += target_cursor;
                            } else {
                                bytes_to_write = target_cursor - byte_to_lock;
                            }

                            var sound_buffer = handmade.GameSoundOutputBuffer{
                                .samples_per_second = @intCast(sound_output.samples_per_second),
                                .sample_count = @intCast(bytes_to_write / sound_output.bytes_per_sample),
                                .samples = @ptrCast(samples),
                            };

                            if (game.getSoundSamples) |getSoundSamples| getSoundSamples(&thread, &game_memory, &sound_buffer);

                            if (debug_mode) {
                                const marker: *win32DebugTimeMarker = &debug_time_markers[debug_time_marker_index];
                                marker.output_play_cursor = play_cursor;
                                marker.output_write_cursor = write_cursor;
                                marker.output_location = byte_to_lock;
                                marker.output_byte_count = bytes_to_write;
                                marker.expected_flip_play_cursor = expected_frame_boundary_byte;

                                var unwrapped_write_cursor: win.DWORD = write_cursor;
                                if (unwrapped_write_cursor < play_cursor) {
                                    unwrapped_write_cursor += sound_output.secondary_buffer_size;
                                }

                                audio_latency_bytes = unwrapped_write_cursor - play_cursor;
                                audio_latency_seconds = (@as(f32, @floatFromInt(audio_latency_bytes)) / @as(f32, @floatFromInt(sound_output.bytes_per_sample))) / @as(f32, @floatFromInt(sound_output.samples_per_second));

                                // std.debug.print("BTL: {}, TC: {}, BTW: {}, - PC: {}, WC: {}, DELTA: {} ({}s)\n", .{
                                //     byte_to_lock,
                                //     target_cursor,
                                //     bytes_to_write,
                                //     play_cursor,
                                //     write_cursor,
                                //     audio_latency_bytes,
                                //     audio_latency_seconds,
                                // });
                            }
                            win32FillSoundBuffer(&sound_output, &sound_buffer, byte_to_lock, bytes_to_write);
                        } else {
                            sound_is_valid = false;
                        }

                        const work_counter: foundation.LARGE_INTEGER = win32GetWallClock();
                        const work_seconds_elapsed: f32 = win32GetSecondsElapsed(last_counter, work_counter);

                        var seconds_elapsed_for_frame: f32 = work_seconds_elapsed;

                        if (seconds_elapsed_for_frame < target_seconds_per_frame) {
                            if (sleep_is_granular) {
                                const sleep_ms: win.DWORD = @intFromFloat(@round(1000.0 * (target_seconds_per_frame - seconds_elapsed_for_frame)));
                                if (sleep_ms > 0) {
                                    zig32.system.threading.Sleep(sleep_ms - 1);
                                }
                            }

                            const test_seconds_elapsed_for_frame = win32GetSecondsElapsed(last_counter, win32GetWallClock());
                            if (test_seconds_elapsed_for_frame < target_seconds_per_frame) {
                                // TODO: Log missed sleep
                            }

                            while (seconds_elapsed_for_frame < target_seconds_per_frame) {
                                seconds_elapsed_for_frame = win32GetSecondsElapsed(last_counter, win32GetWallClock());
                            }
                        } else {
                            // TODO: (CASEY) Missed Frame Rate
                            // TODO: Logging
                        }

                        const end_counter: foundation.LARGE_INTEGER = win32GetWallClock();
                        const ms_per_frame: f32 = 1000.0 * win32GetSecondsElapsed(last_counter, end_counter);
                        const counter_elapsed: i64 = end_counter.QuadPart - last_counter.QuadPart;
                        last_counter = end_counter;

                        const dimension = win32GetWindowDimension(window);

                        flip_wall_clock = win32GetWallClock();
                        if (debug_mode) {
                            // NOTE: (FlipMarker) Flip marker code is here instead of lower block, because it's more correct, but still not quite right.
                            if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor))) {
                                std.debug.assert(debug_time_marker_index < debug_time_markers.len);
                                const marker: *win32DebugTimeMarker = &debug_time_markers[debug_time_marker_index];
                                marker.flip_play_cursor = play_cursor;
                                marker.flip_write_cursor = write_cursor;
                            }
                            // const current_debug_time_marker_index: u32 = if (debug_time_marker_index == 0) (debug_time_markers.len - 1) else debug_time_marker_index;
                            // win32DebugSyncDisplay(&global_back_buffer, &sound_output, &debug_time_markers, debug_time_markers.len, current_debug_time_marker_index);
                        }

                        win32DisplayBufferInWindow(&global_back_buffer, device_context.?, dimension.width, dimension.height);

                        // NOTE: (FlipMarker) Casey has this code here and it works for him, but it draws in the wrong place for me.
                        // if (debug_mode) {
                        //     if (zig32.zig.SUCCEEDED(global_secondary_buffer.?.IDirectSoundBuffer.GetCurrentPosition(&play_cursor, &write_cursor))) {
                        //         std.debug.assert(debug_time_marker_index < debug_time_markers.len);
                        //         const marker: *win32DebugTimeMarker = &debug_time_markers[debug_time_marker_index];
                        //         marker.flip_play_cursor = play_cursor;
                        //         marker.flip_write_cursor = write_cursor;
                        //     }
                        // }

                        const temp: *handmade.GameInput = new_input;
                        new_input = old_input;
                        old_input = temp;

                        const end_cycle_count: i64 = @intCast(rdtsc());
                        const cycles_elapsed: i64 = end_cycle_count - last_cycle_count;
                        last_cycle_count = end_cycle_count;

                        const frames_per_second: f32 = @as(f32, @floatFromInt(global_perf_count_frequency)) / @as(f32, @floatFromInt(counter_elapsed));
                        const mega_cycles_per_frame: f32 = (@as(f32, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0));

                        _ = ms_per_frame;
                        _ = frames_per_second;
                        _ = mega_cycles_per_frame;
                        // std.debug.print("ms/f: {d:.2}, f/s: {d:.2}, mega_cycles/f {d:.2}\n", .{ ms_per_frame, frames_per_second, mega_cycles_per_frame });
                        if (debug_mode) {
                            debug_time_marker_index += 1;
                            if (debug_time_marker_index >= debug_time_markers.len) {
                                debug_time_marker_index = 0;
                            }
                        }
                    }
                } else {
                    // TODO: Logging
                }
            } else {
                // TODO: Logging
            }
        }
    } else {
        // TODO: Logging
    }
}

pub export fn wWinMain(hInstance: foundation.HINSTANCE, _: foundation.HINSTANCE, _: foundation.PWSTR, _: win.INT) callconv(.c) win.INT {
    instance = hInstance;
    run() catch return 1;
    return 0;
}
