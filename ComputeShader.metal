#include <metal_stdlib>
using namespace metal;

kernel void audioProcessingKernel(device float* inAudio [[buffer(0)]],
                                  device float* outAudio [[buffer(1)]],
                                  uint id [[thread_position_in_grid]])
{
    float sample = inAudio[id];
    // Simple processing: Amplify the audio signal
    outAudio[id] = sample * 2.0;
}

