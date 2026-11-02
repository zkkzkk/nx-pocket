// A game's icon (its control data's 256×256 JPEG) made larger for the screens that show it large (NX Pocket's selected tile, NX Pocket for Mac's game page), on this
// Mac and nothing else: no network, no model. A light noise reduction first (the JPEG's 8×8 blocks would grow with it), then MetalFX's spatial scaler (edge-adaptive,
// as games upscale their frames), else Core Image's Lanczos where Metal 3's MetalFX is not there, then a light sharpening; written as PNG.
// Usage: xcrun swift upscale_icon.swift <in image> <out .png> [size, default 1024]   (build_pack.py runs it for icon@4x.png)
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import MetalFX
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: upscale_icon.swift <in> <out.png> [size]\n".data(using: .utf8)!); exit(2) }
let side = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
guard let src = CIImage(contentsOf: URL(fileURLWithPath: args[1])) else { FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!); exit(1) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])

// 1. the JPEG's blocks smoothed, its edges kept
let nr = CIFilter.noiseReduction(); nr.inputImage = src; nr.noiseLevel = 0.01; nr.sharpness = 0.4
let clean = nr.outputImage!.cropped(to: src.extent)
let w = Int(src.extent.width), h = Int(src.extent.height)

// 2. MetalFX, else Lanczos
func metalFX(_ image: CIImage) -> CIImage? {
    guard let dev = MTLCreateSystemDefaultDevice(), MTLFXSpatialScalerDescriptor.supportsDevice(dev), let queue = dev.makeCommandQueue() else { return nil }
    let d = MTLFXSpatialScalerDescriptor()
    d.inputWidth = w; d.inputHeight = h; d.outputWidth = side; d.outputHeight = side
    d.colorTextureFormat = .rgba8Unorm; d.outputTextureFormat = .rgba8Unorm; d.colorProcessingMode = .perceptual
    guard let scaler = d.makeSpatialScaler(device: dev) else { return nil }
    let inDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    inDesc.usage = scaler.colorTextureUsage.union([.shaderWrite, .shaderRead])
    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
    outDesc.usage = scaler.outputTextureUsage.union(.shaderRead); outDesc.storageMode = .private
    guard let input = dev.makeTexture(descriptor: inDesc), let output = dev.makeTexture(descriptor: outDesc), let cb = queue.makeCommandBuffer() else { return nil }
    // Core Image draws the image the right way up into the texture (Metal's origin is top left, Core Image's bottom left)
    ci.render(image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h))), to: input, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: space)
    scaler.colorTexture = input; scaler.outputTexture = output; scaler.inputContentWidth = w; scaler.inputContentHeight = h
    scaler.encode(commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    guard let out = CIImage(mtlTexture: output, options: [.colorSpace: space]) else { return nil }
    return out.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(side)))
}
func lanczos(_ image: CIImage) -> CIImage {
    let f = CIFilter.lanczosScaleTransform(); f.inputImage = image; f.scale = Float(side) / Float(h); f.aspectRatio = 1   // square icons
    return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
}
let (big, how) = metalFX(clean).map { ($0, "MetalFX") } ?? (lanczos(clean), "Lanczos")

// 3. a light sharpening of the luminance (colour edges stay as they were)
let sh = CIFilter.sharpenLuminance(); sh.inputImage = big; sh.sharpness = 0.25; sh.radius = 1.4   // more makes dark rims round the letters
let result = sh.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))

guard let cg = ci.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: space),
      let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dst, cg, nil)
guard CGImageDestinationFinalize(dst) else { exit(1) }
print("\(args[2]): \(side)×\(side) (\(how))")
