#!/bin/bash

# Compile the Metal shader
xcrun -sdk macosx metal -c ComputeShader.metal -o ComputeShader.air

# Create a metallib from the compiled shader
xcrun -sdk macosx metallib ComputeShader.air -o ComputeShader.metallib

# Compile the Objective-C source code
clang -framework Foundation -framework Metal -framework QuartzCore -framework AppKit -framework AVFoundation -framework CoreMedia -o MetalLiveAudio main.m
