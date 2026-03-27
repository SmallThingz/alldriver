const std = @import("std");
const builtin = @import("builtin");

pub fn io() std.Io {
    return std.Options.debug_io;
}

pub fn milliTimestamp() i64 {
    return @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io(), .real).nanoseconds, std.time.ns_per_ms)));
}

pub fn nanoTimestamp() i128 {
    return @as(i128, @intCast(std.Io.Timestamp.now(io(), .real).nanoseconds));
}

pub fn timestamp() i64 {
    return @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io(), .real).nanoseconds, std.time.ns_per_s)));
}

pub fn sleepMs(ms: u64) void {
    std.Io.sleep(io(), std.Io.Duration.fromMilliseconds(@as(i64, @intCast(ms))), .awake) catch unreachable;
}

pub fn sleepNs(ns: u64) void {
    std.Io.sleep(io(), std.Io.Duration.fromNanoseconds(@as(i96, @intCast(ns))), .awake) catch unreachable;
}

pub const Mutex = struct {
    inner: std.Io.Mutex = std.Io.Mutex.init,

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    pub fn lock(self: *Mutex) void {
        self.inner.lock(io()) catch unreachable;
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = std.Io.Condition.init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.wait(io(), &mutex.inner) catch unreachable;
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};

pub const CwdDir = struct {
    inner: std.Io.Dir = std.Io.Dir.cwd(),

    pub fn access(self: CwdDir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
        return self.inner.access(io(), sub_path, options);
    }

    pub fn statFile(self: CwdDir, sub_path: []const u8) std.Io.Dir.StatFileError!std.Io.File.Stat {
        return self.inner.statFile(io(), sub_path, .{});
    }

    pub fn makePath(self: CwdDir, sub_path: []const u8) std.Io.Dir.CreateDirPathError!void {
        return self.inner.createDirPath(io(), sub_path);
    }

    pub fn writeFile(self: CwdDir, options: std.Io.Dir.WriteFileOptions) std.Io.Dir.WriteFileError!void {
        return self.inner.writeFile(io(), options);
    }

    pub fn readFileAlloc(
        self: CwdDir,
        allocator: std.mem.Allocator,
        sub_path: []const u8,
        max_bytes: usize,
    ) std.Io.Dir.ReadFileAllocError![]u8 {
        return self.inner.readFileAlloc(io(), sub_path, allocator, .limited(max_bytes));
    }

    pub fn createFile(
        self: CwdDir,
        sub_path: []const u8,
        flags: std.Io.File.CreateFlags,
    ) std.Io.File.OpenError!std.Io.File {
        return self.inner.createFile(io(), sub_path, flags);
    }

    pub fn openFile(
        self: CwdDir,
        sub_path: []const u8,
        flags: std.Io.File.OpenFlags,
    ) std.Io.File.OpenError!std.Io.File {
        return self.inner.openFile(io(), sub_path, flags);
    }

    pub fn openDir(
        self: CwdDir,
        sub_path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        return self.inner.openDir(io(), sub_path, options);
    }

    pub fn deleteFile(self: CwdDir, sub_path: []const u8) std.Io.Dir.DeleteFileError!void {
        return self.inner.deleteFile(io(), sub_path);
    }

    pub fn deleteTree(self: CwdDir, sub_path: []const u8) std.Io.Dir.DeleteTreeError!void {
        return self.inner.deleteTree(io(), sub_path);
    }

    pub fn rename(self: CwdDir, old_sub_path: []const u8, new_sub_path: []const u8) std.Io.Dir.RenameError!void {
        return self.inner.rename(old_sub_path, self.inner, new_sub_path, io());
    }

    pub fn copyFile(
        self: CwdDir,
        source_path: []const u8,
        dest_dir: CwdDir,
        dest_path: []const u8,
        options: std.Io.Dir.CopyFileOptions,
    ) std.Io.Dir.CopyFileError!void {
        return self.inner.copyFile(source_path, dest_dir.inner, dest_path, io(), options);
    }

    pub fn realpathAlloc(
        self: CwdDir,
        allocator: std.mem.Allocator,
        sub_path: []const u8,
    ) std.Io.Dir.RealPathFileAllocError![:0]u8 {
        return self.inner.realPathFileAlloc(io(), sub_path, allocator);
    }
};

pub fn cwd() CwdDir {
    return .{};
}

pub fn openDirAbsolute(path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io(), path, options);
}

pub fn openFileAbsolute(path: []const u8, flags: std.Io.File.OpenFlags) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.openFileAbsolute(io(), path, flags);
}

pub fn createFileAbsolute(path: []const u8, flags: std.Io.File.CreateFlags) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.createFileAbsolute(io(), path, flags);
}

pub fn dirWriteFile(dir: std.Io.Dir, options: std.Io.Dir.WriteFileOptions) std.Io.Dir.WriteFileError!void {
    return dir.writeFile(io(), options);
}

pub fn dirMakePath(dir: std.Io.Dir, sub_path: []const u8) std.Io.Dir.CreateDirPathError!void {
    return dir.createDirPath(io(), sub_path);
}

pub fn dirRealpathAlloc(
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    sub_path: []const u8,
) std.Io.Dir.RealPathFileAllocError![:0]u8 {
    return dir.realPathFileAlloc(io(), sub_path, allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) std.process.Environ.GetAllocError![]u8 {
    const threaded = std.Options.debug_threaded_io orelse return error.EnvironmentVariableMissing;
    return threaded.environ.process_environ.getAlloc(allocator, name);
}

pub fn canCreateIpv4TcpSocket() bool {
    if (builtin.os.tag != .linux) return true;
    const linux = std.os.linux;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            _ = linux.close(@intCast(rc));
            return true;
        },
        .PERM, .ACCES => return false,
        else => return true,
    }
}
