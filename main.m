#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

#define BUFFER_SIZE 512

@interface AudioProcessor : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLComputePipelineState> computePipelineState;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@end

@implementation AudioProcessor {
    float inputBuffer[BUFFER_SIZE];
    uint8_t pixelData[800 * 600 * 4]; // RGBA format for 800x600 pixels
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            NSLog(@"Metal is not supported on this device");
            return nil;
        }

        _commandQueue = [_device newCommandQueue];

        NSError *error = nil;
        NSString *shaderSource = @"#include <metal_stdlib>\n"
                                  "using namespace metal;\n"
                                  "kernel void audioProcessingKernel(device float* inAudio [[buffer(0)]], "
                                  "texture2d<float, access::write> outTexture [[texture(0)]], "
                                  "uint2 gid [[thread_position_in_grid]]) { "
                                  "float sample = inAudio[gid.x]; "
                                  "float colorValue = abs(sample) * 255.0; "
                                  "float4 color = float4(colorValue, colorValue, colorValue, 1.0); "
                                  "outTexture.write(color, gid); "
                                  "}";
        id<MTLLibrary> defaultLibrary = [_device newLibraryWithSource:shaderSource options:nil error:&error];
        if (error) {
            NSLog(@"Failed to create default library: %@", error);
            return nil;
        }

        id<MTLFunction> kernelFunction = [defaultLibrary newFunctionWithName:@"audioProcessingKernel"];
        _computePipelineState = [_device newComputePipelineStateWithFunction:kernelFunction error:&error];
        if (error) {
            NSLog(@"Failed to create pipeline state: %@", error);
            return nil;
        }

        _captureSession = [[AVCaptureSession alloc] init];
        AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (!audioDevice) {
            NSLog(@"Failed to get audio device");
            return nil;
        }

        AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
        if (error) {
            NSLog(@"Failed to create audio input: %@", error);
            return nil;
        }

        if ([_captureSession canAddInput:audioInput]) {
            [_captureSession addInput:audioInput];
        } else {
            NSLog(@"Failed to add audio input to capture session");
            return nil;
        }

        AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
        [audioOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
        if ([_captureSession canAddOutput:audioOutput]) {
            [_captureSession addOutput:audioOutput];
        } else {
            NSLog(@"Failed to add audio output to capture session");
            return nil;
        }

        NSWindow *window = [NSWindow alloc];
        [window initWithContentRect:NSMakeRect(0, 0, 800, 600)
                           styleMask:(NSWindowStyleMaskTitled |
                                      NSWindowStyleMaskClosable |
                                      NSWindowStyleMaskResizable)
                             backing:NSBackingStoreBuffered
                               defer:NO];
        [window setTitle:@"Live Audio Amplitude"];
        [window makeKeyAndOrderFront:nil];

        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = _device;
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _metalLayer.framebufferOnly = YES;
        _metalLayer.frame = window.contentView.layer.bounds;
        [window.contentView setLayer:_metalLayer];
        [window.contentView setWantsLayer:YES];

        [_captureSession startRunning];
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        NSLog(@"Failed to get block buffer");
        return;
    }

    size_t length = 0;
    char *dataPointer = NULL;
    CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &length, &dataPointer);
    if (!dataPointer) {
        NSLog(@"Failed to get data pointer");
        return;
    }


int sampleCount = (int)length / sizeof(float);
    for (int i = 0; i < MIN(sampleCount, BUFFER_SIZE); i++) {
        inputBuffer[i] = ((float *)dataPointer)[i];
    }

    [self processAudio];
}

- (void)processAudio {
    @autoreleasepool {
        id<MTLBuffer> inBuffer = [_device newBufferWithBytes:inputBuffer length:BUFFER_SIZE * sizeof(float) options:MTLResourceStorageModeShared];
        
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                     width:800
                                                                                                    height:600
                                                                                                 mipmapped:NO];
        id<MTLTexture> outTexture = [_device newTextureWithDescriptor:textureDescriptor];
        
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
        [computeEncoder setComputePipelineState:_computePipelineState];
        [computeEncoder setBuffer:inBuffer offset:0 atIndex:0];
        [computeEncoder setTexture:outTexture atIndex:0];
        
        MTLSize gridSize = MTLSizeMake(BUFFER_SIZE, 1, 1);
        MTLSize threadGroupSize = MTLSizeMake(1, 1, 1);
        [computeEncoder dispatchThreadgroups:gridSize threadsPerThreadgroup:threadGroupSize];
        [computeEncoder endEncoding];
        
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        
        [outTexture getBytes:pixelData bytesPerRow:800*4 fromRegion:MTLRegionMake2D(0, 0, 800, 600) mipmapLevel:0];
        [self displayAmplitude];
    }
}

- (void)displayAmplitude {
    @autoreleasepool {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixelData,
                                                     800,
                                                     600,
                                                     8,
                                                     800*4,
                                                     colorSpace,
                                                     kCGImageAlphaNoneSkipLast);
        
        CGImageRef cgImage = CGBitmapContextCreateImage(context);
        
        NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(800, 600)];
        
        CGImageRelease(cgImage);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [_metalLayer setContents:image];
        });
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        AudioProcessor *processor = [[AudioProcessor alloc] init];
        if (processor) {
            [[NSRunLoop mainRunLoop] run];
        }
    }
    return 0;
}

