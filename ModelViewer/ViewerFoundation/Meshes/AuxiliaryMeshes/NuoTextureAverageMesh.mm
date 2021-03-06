//
//  NuoTextureAverageMesh.m
//  ModelViewer
//
//  Created by Dong on 11/11/17.
//  Copyright © 2017 middleware. All rights reserved.
//

#import "NuoTextureAverageMesh.h"

#import "NuoComputeEncoder.h"
#import "NuoRenderPassTarget.h"
#import "NuoTextureMesh.h"
#import "NuoRenderPassAttachment.h"




@implementation NuoTextureAverageMesh
{
    // mesh used to duplicate texture
    NuoTextureMesh* _accumulatedMesh;
    
    NuoRenderPassTarget* _texturesAccumulated;
    id<MTLTexture> _textureLatest;
    uint32_t _textureCount;
    
    NSArray<id<MTLBuffer>>* _texCountBuffer;
}


- (instancetype)initWithCommandQueue:(id<MTLCommandQueue>)commandQueue
{
    self = [super initWithCommandQueue:commandQueue];
    
    if (self)
    {
        id<MTLBuffer> buffers[kInFlightBufferCount];
        for (size_t i = 0; i < kInFlightBufferCount; ++i)
            buffers[i] = [commandQueue.device newBufferWithLength:sizeof(uint32_t)
                                                          options:MTLResourceStorageModeManaged];
        _texCountBuffer = [[NSArray alloc] initWithObjects:buffers count:kInFlightBufferCount];
        
        _textureCount = 0;
    }
    
    return self;
}


- (void)makePipelineAndSampler
{
    NSString* shaderName = @"fragment_texutre_average";
    
    _texturesAccumulated = [[NuoRenderPassTarget alloc] initWithCommandQueue:self.commandQueue
                                                             withPixelFormat:MTLPixelFormatRGBA32Float
                                                             withSampleCount:1];
    
    _texturesAccumulated.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _texturesAccumulated.manageTargetTexture = YES;
    _texturesAccumulated.name = @"Average Texture";
    
    _accumulatedMesh = [[NuoTextureMesh alloc] initWithCommandQueue:self.commandQueue];
    _accumulatedMesh.sampleCount = 1;
    [_accumulatedMesh makePipelineAndSampler:MTLPixelFormatRGBA32Float withBlendMode:kBlend_Alpha];
    
    [self makePipelineAndSampler:MTLPixelFormatRGBA32Float withFragementShader:shaderName
                   withBlendMode:kBlend_Accumulate];
}



- (void)appendTexture:(id<MTLTexture>)texture
{
    _textureLatest = texture;
    _textureCount += 1;
}



- (void)accumulateTexture:(id<MTLTexture>)texture
                 onTarget:(NuoRenderPassTarget*)target
             withInFlight:(NSUInteger)inFlight
        withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    [self appendTexture:texture];
    
    // accumulate the texture onto the target
    
    id<MTLRenderCommandEncoder> renderPass = [target retainRenderPassEndcoder:commandBuffer];
    renderPass.label = @"Motion Blur Pass";
    
    [self drawMesh:renderPass indexBuffer:inFlight];
    [target releaseRenderPassEndcoder];
    
    // copy pixels from the render target to the accumulation texture
    
    [self setAccumulateTexture:target.targetTexture withCommandBuffer:commandBuffer];
}


- (void)setAccumulateTexture:(id<MTLTexture>)texture withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    [_texturesAccumulated setDrawableSize:CGSizeMake(texture.width, texture.height)];
    
    /*id<MTLRenderCommandEncoder> accumulatePass = [_texturesAccumulated retainRenderPassEndcoder:commandBuffer];
    [_accumulatedMesh setModelTexture:texture];
    [_accumulatedMesh drawMesh:accumulatePass indexBuffer:0];
    [_texturesAccumulated releaseRenderPassEndcoder];*/
    
    /**
     *  BLIT copy can NOT handle framebuffer-only source texture, nor can it handle texture size change.
     *
     *  the code above change _texturesAccumulated to a render-target, which resolves the texture creation,
     *  and texture copy by rendering
     *
    if (!_texturesAccumulated)
    {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:texture.width
        height:texture.height
        mipmapped:NO];
        desc.sampleCount = 1;
        desc.textureType = MTLTextureType2D;
        desc.resourceOptions = MTLResourceStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

        _texturesAccumulated = [self.device newTextureWithDescriptor:desc];
    } */
    
    MTLOrigin origin = {0, 0, 0};
    MTLSize size = {texture.width, texture.height, 1};
    id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:origin sourceSize:size
                   toTexture:_texturesAccumulated.targetTexture destinationSlice:0 destinationLevel:0 destinationOrigin:origin];
    
    [encoder endEncoding];
}



- (void)updateUniform:(NSInteger)bufferIndex withTransform:(const NuoMatrixFloat44&)transform
{
    /*AccumulateUniform uniform;
    uniform.frameIndex = _textureCount;
    uniform.width = _texturesAccumulated.drawableSize.width;
    uniform.height = _texturesAccumulated.drawableSize.height;
    
    memcpy(_texCountBuffer[bufferIndex].contents, &uniform, sizeof(AccumulateUniform));
    [_texCountBuffer[bufferIndex] didModifyRange:NSMakeRange(0, sizeof(AccumulateUniform))];*/
    
    memcpy(_texCountBuffer[bufferIndex].contents, &_textureCount, sizeof(int));
    [_texCountBuffer[bufferIndex] didModifyRange:NSMakeRange(0, sizeof(int))];
}



- (void)drawMesh:(id<MTLRenderCommandEncoder>)renderPass indexBuffer:(NSInteger)index
{
    [self updateUniform:index withTransform:NuoMatrixFloat44Identity];
    
    [renderPass setFragmentTexture:_texturesAccumulated.targetTexture atIndex:0];
    [renderPass setFragmentTexture:_textureLatest atIndex:1];
    [renderPass setFragmentBuffer:_texCountBuffer[index] offset:0 atIndex:0];
    [super drawMesh:renderPass indexBuffer:index];
}



@end





@implementation NuoTextureAccumulator
{
    // mesh used to duplicate texture when the target is frame buffer only
    //
    NuoTextureMesh* _accumulatedMesh;
    
    NuoRenderPassTarget* _texturesAccumulated;
    
    id<MTLCommandQueue> _commandQueue;
    NuoComputePipeline* _pipelineState;
    NuoComputePipeline* _pipelineStateCopy;
    
    id<MTLTexture> _textureLatest;
    uint32_t _textureCount;
    
    NSArray<id<MTLBuffer>>* _texCountBuffer;
}


- (instancetype)initWithCommandQueue:(id<MTLCommandQueue>)commandQueue
{
    self = [super init];
    
    if (self)
    {
        _commandQueue = commandQueue;
        
        id<MTLBuffer> buffers[kInFlightBufferCount];
        for (size_t i = 0; i < kInFlightBufferCount; ++i)
            buffers[i] = [commandQueue.device newBufferWithLength:sizeof(uint32_t)
                                                          options:MTLResourceStorageModeManaged];
        _texCountBuffer = [[NSArray alloc] initWithObjects:buffers count:kInFlightBufferCount];
        
        _textureCount = 0;
    }
    
    return self;
}


- (void)makePipelineAndSampler
{
    NSString* shaderName = @"compute_texutre_average";
    
    _texturesAccumulated = [[NuoRenderPassTarget alloc] initWithCommandQueue:_commandQueue
                                                             withPixelFormat:MTLPixelFormatRGBA32Float
                                                             withSampleCount:1];
    
    _texturesAccumulated.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _texturesAccumulated.manageTargetTexture = YES;
    _texturesAccumulated.colorAttachments[0].needWrite = YES;
    _texturesAccumulated.name = @"Average Texture";
    
    _accumulatedMesh = [[NuoTextureMesh alloc] initWithCommandQueue:_commandQueue];
    _accumulatedMesh.sampleCount = 1;
    [_accumulatedMesh makePipelineAndSampler:MTLPixelFormatBGRA8Unorm withBlendMode:kBlend_None];
    
    _pipelineState = [[NuoComputePipeline alloc] initWithDevice:_commandQueue.device withFunction:shaderName
                                                  withParameter:NO];
    _pipelineStateCopy = [[NuoComputePipeline alloc] initWithDevice:_commandQueue.device withFunction:@"compute_texture_copy"
                                                      withParameter:NO];
    
    _pipelineState.name = @"Average Accumulation";
    _pipelineStateCopy.name = @"Texture Copy";
}



- (void)appendTexture:(id<MTLTexture>)texture
{
    _textureLatest = texture;
    _textureCount += 1;
    
    [_texturesAccumulated setDrawableSize:CGSizeMake(texture.width, texture.height)];
}



- (void)accumulateTexture:(id<MTLTexture>)texture
                 onTarget:(NuoRenderPassTarget*)target
             withInFlight:(NSUInteger)inFlight
        withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    [self accumulateTexture:texture withInFlight:inFlight withCommandBuffer:commandBuffer];
    [self outputAccumulateToTarget:target withCommandBuffer:commandBuffer];
}


- (void)accumulateTexture:(id<MTLTexture>)texture
                onTexture:(id<MTLTexture>)targetTexture
             withInFlight:(NSUInteger)inFlight
        withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    [self accumulateTexture:texture withInFlight:inFlight withCommandBuffer:commandBuffer];
    [self outputAccumulateToTexture:targetTexture withCommandBuffer:commandBuffer];
}


- (void)accumulateTexture:(id<MTLTexture>)texture
             withInFlight:(NSUInteger)inFlight
        withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    [self appendTexture:texture];
    [self updateUniform:inFlight];
    
    NuoComputeEncoder* encoder = [_pipelineState encoderWithCommandBuffer:commandBuffer];
    
    [encoder setTexture:_texturesAccumulated.targetTexture atIndex:0];
    [encoder setTexture:_textureLatest atIndex:1];
    [encoder setBuffer:_texCountBuffer[inFlight] offset:0 atIndex:0];
    
    [encoder dispatch];
}


- (void)outputAccumulateToTarget:(NuoRenderPassTarget*)target withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    if (!target.manageTargetTexture)
    {
        id<MTLRenderCommandEncoder> accumulatePass = [target retainRenderPassEndcoder:commandBuffer];
        [_accumulatedMesh setModelTexture:_texturesAccumulated.targetTexture];
        [_accumulatedMesh drawMesh:accumulatePass indexBuffer:0];
        [target releaseRenderPassEndcoder];
    }
    else
    {
        [self outputAccumulateToTexture:target.targetTexture withCommandBuffer:commandBuffer];
    }
}
    
- (void)outputAccumulateToTexture:(id<MTLTexture>)targetTexture withCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    NuoComputeEncoder* encoder = [_pipelineStateCopy encoderWithCommandBuffer:commandBuffer];
    
    [encoder setTexture:targetTexture atIndex:0];
    [encoder setTexture:_texturesAccumulated.targetTexture atIndex:1];
    [encoder dispatch];
}



- (void)updateUniform:(NSInteger)bufferIndex
{
    memcpy(_texCountBuffer[bufferIndex].contents, &_textureCount, sizeof(uint32_t));
    [_texCountBuffer[bufferIndex] didModifyRange:NSMakeRange(0, sizeof(uint32_t))];
}




@end
