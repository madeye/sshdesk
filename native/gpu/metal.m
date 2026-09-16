#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>

// ARC owns all Metal resources. Zig serializes access and destroys the context
// after its capture/input workers have joined.
@interface SSHDeskMetal : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLComputePipelineState> pipeline;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *buffers;
@end
@implementation SSHDeskMetal
@end

void *sshdesk_metal_create(const char *source) {
    @autoreleasepool {
        SSHDeskMetal *context = [SSHDeskMetal new];
        context.device = MTLCreateSystemDefaultDevice();
        if (!context.device) return NULL;
        NSError *error = nil;
        id<MTLLibrary> library = [context.device newLibraryWithSource:
            [NSString stringWithUTF8String:source] options:nil error:&error];
        if (!library) return NULL;
        id<MTLFunction> function = [library newFunctionWithName:@"resize_pass"];
        if (!function) return NULL;
        context.pipeline = [context.device newComputePipelineStateWithFunction:function error:&error];
        context.queue = [context.device newCommandQueue];
        if (!context.pipeline || !context.queue) return NULL;
        context.buffers = [NSMutableArray new];
        for (unsigned i = 0; i < 4; ++i) {
            id<MTLBuffer> buffer = [context.device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            if (!buffer) return NULL;
            [context.buffers addObject:buffer];
        }
        return (__bridge_retained void *)context;
    }
}
void sshdesk_metal_destroy(void *pointer) {
    @autoreleasepool { __unused id context = (__bridge_transfer id)pointer; }
}
int sshdesk_metal_pass(void *pointer, const void *source, size_t source_size,
                       const void *spans, size_t spans_size, const void *weights, size_t weights_size,
                       void *output, uint32_t source_width, uint32_t width, uint32_t height, uint32_t vertical) {
    @autoreleasepool {
        SSHDeskMetal *context = (__bridge SSHDeskMetal *)pointer;
        const size_t sizes[4] = { source_size, spans_size, weights_size, (size_t)width * height * 4 };
        for (unsigned i = 0; i < 4; ++i) {
            if (sizes[i] > context.device.maxBufferLength) return 0;
            if (context.buffers[i].length < sizes[i]) {
                id<MTLBuffer> buffer = [context.device newBufferWithLength:sizes[i] options:MTLResourceStorageModeShared];
                if (!buffer) return 0;
                context.buffers[i] = buffer;
            }
        }
        memcpy(context.buffers[0].contents, source, source_size);
        memcpy(context.buffers[1].contents, spans, spans_size);
        memcpy(context.buffers[2].contents, weights, weights_size);
        id<MTLCommandBuffer> command = [context.queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!command || !encoder) return 0;
        [encoder setComputePipelineState:context.pipeline];
        for (unsigned i = 0; i < 4; ++i) [encoder setBuffer:context.buffers[i] offset:0 atIndex:i];
        const uint32_t geometry[4] = { source_width, width, height, vertical };
        [encoder setBytes:geometry length:sizeof geometry atIndex:4];
        const NSUInteger lanes = context.pipeline.threadExecutionWidth;
        [encoder dispatchThreadgroups:MTLSizeMake((width + lanes - 1) / lanes, height, 1)
                threadsPerThreadgroup:MTLSizeMake(lanes, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) return 0;
        memcpy(output, context.buffers[3].contents, sizes[3]);
        return 1;
    }
}
