const std = @import("std");

pub fn unsignedToFloat(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const half_u = (std.math.maxInt(SrcType) + 1) / 2;
    const half_f = @as(DstType, @floatFromInt(half_u));

    const div_by_half_f = 1.0 / half_f;
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrcType = @Vector(vec_size, SrcType);
        const VecDstType = @Vector(vec_size, DstType);

        // multiplies everything by half
        const half_vec: VecDstType = @splat(half_f);
        const block_len = len - (len % vec_size);

        const div_by_half_f_vec: VecDstType = @splat(div_by_half_f);

        while (i < block_len) : (i += vec_size) {
            const src_values = std.mem.bytesAsValue(VecSrcType, src[i * src_stride ..][0 .. vec_size * src_stride]).*;

            // int to float vector
            const src_f_vec: VecDstType = @floatFromInt(src_values);
            const sub_result: VecDstType = src_f_vec - half_vec;
            const dst_vec: VecDstType = sub_result * div_by_half_f_vec;

            @memcpy(dst[i * dst_stride ..][0 .. vec_size * dst_stride], std.mem.asBytes(&dst_vec)[0 .. vec_size * dst_stride]);
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(@alignCast(src[i * src_stride ..][0..src_stride]));

        const src_sample_f = @as(DstType, @floatFromInt(src_sample.*));
        const dst_sample: DstType = (src_sample_f - half_f) * div_by_half_f;

        @memcpy(dst[i * dst_stride ..][0..dst_stride], std.mem.asBytes(&dst_sample)[0..dst_stride]);
    }
}

pub fn signedToFloat(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const div_by_max = 1.0 / @as(comptime_float, std.math.maxInt(SrcType) + 1);
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrc = @Vector(vec_size, SrcType);
        const VecDst = @Vector(vec_size, DstType);
        const vec_blocks_len = len - (len % vec_size);
        const div_by_max_vec: VecDst = @splat(div_by_max);
        while (i < vec_blocks_len) : (i += vec_size) {
            const src_vec = std.mem.bytesAsValue(VecSrc, src[i * src_stride ..][0 .. vec_size * src_stride]).*;
            const dst_sample: VecDst = @as(VecDst, @floatFromInt(src_vec)) * div_by_max_vec;
            @memcpy(dst[i * dst_stride ..][0 .. vec_size * dst_stride], std.mem.asBytes(&dst_sample)[0 .. vec_size * dst_stride]);
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(@alignCast(src[i * src_stride ..][0..src_stride]));
        const dst_sample: DstType = @as(DstType, @floatFromInt(src_sample.*)) * div_by_max;
        @memcpy(dst[i * dst_stride ..][0..dst_stride], std.mem.asBytes(&dst_sample)[0..dst_stride]);
    }
}
