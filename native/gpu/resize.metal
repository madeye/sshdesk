#include <metal_stdlib>
using namespace metal;
struct Span { uint first, length, offset, error; };
struct Geometry { uint source_width, width, height, vertical; };
kernel void resize_pass(device const uchar *source [[buffer(0)]],
                        device const Span *spans [[buffer(1)]],
                        device const uint *weights [[buffer(2)]],
                        device uchar4 *output [[buffer(3)]],
                        constant Geometry &g [[buffer(4)]],
                        uint2 p [[thread_position_in_grid]]) {
    if (p.x >= g.width || p.y >= g.height) return;
    const Span span = spans[g.vertical ? p.y : p.x];
    uint3 sum = uint3(0);
    for (uint i = 0; i < span.length; ++i) {
        const uint index = g.vertical ? (span.first + i) * g.source_width + p.x
                                      : p.y * g.source_width + span.first + i;
        const uint3 rgb(source[3 * index], source[3 * index + 1], source[3 * index + 2]);
        sum += rgb * weights[span.offset + i];
    }
    const uint unit = 1u << 22;
    const uint3 fraction = sum & (unit - 1);
    const uint3 distance = select(unit / 2 - fraction, fraction - unit / 2, fraction >= unit / 2);
    const uint flags = uint(distance.x <= span.error) | (uint(distance.y <= span.error) << 1)
                       | (uint(distance.z <= span.error) << 2);
    output[p.y * g.width + p.x] = uchar4(uchar3((sum + unit / 2) >> 22), uchar(flags));
}
