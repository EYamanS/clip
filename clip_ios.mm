// Clip Library
// Copyright (c) 2026 Emir Yaman Sivrikaya
//
// This file is released under the terms of the MIT license.
// Read LICENSE.txt for more information.

#include "clip.h"
#include "clip_common.h"
#include "clip_lock_impl.h"

#include <cassert>
#include <cstring>
#include <map>
#include <vector>

#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

namespace clip {

namespace {

  format g_last_format = 100;
  std::map<std::string, format> g_name_to_format;
  std::map<format, std::string> g_format_to_name;

  // UIPasteboard replaces all its content each time we set a value,
  // so we accumulate all the values set in the same lock to set them
  // in only one pasteboard item.
  NSMutableDictionary<NSString*, id>* g_pending = nil;

  NSString* const kTextType = @"public.utf8-plain-text";
  NSString* const kPngType = @"public.png";

  NSString* format_name(format f) {
    auto it = g_format_to_name.find(f);
    if (it == g_format_to_name.end())
      return nil;
    return [NSString stringWithUTF8String:it->second.c_str()];
  }

  void set_pending_value(NSString* type, id value) {
    if (!g_pending)
      g_pending = [NSMutableDictionary dictionary];
    g_pending[type] = value;
    [UIPasteboard generalPasteboard].items = @[ [g_pending copy] ];
  }

#if CLIP_ENABLE_IMAGE

  // Returns the number of bits of the given mask
  int mask_bits(unsigned long mask) {
    int n = 0;
    for (; mask; mask >>= 1)
      if (mask & 1)
        ++n;
    return n;
  }

  int scale_component(unsigned long value, int bits) {
    if (bits <= 0)
      return 0;
    if (bits == 8)
      return int(value);
    return int(value * 255 / ((1ul << bits) - 1));
  }

  bool get_image_from_pasteboard(image* output_img, image_spec* output_spec) {
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
    if (!pasteboard.hasImages)
      return false;

    UIImage* uiImage = pasteboard.image;
    if (!uiImage || !uiImage.CGImage)
      return false;

    CGImageRef cgImage = uiImage.CGImage;
    const size_t w = CGImageGetWidth(cgImage);
    const size_t h = CGImageGetHeight(cgImage);
    if (w == 0 || h == 0)
      return false;

    image_spec spec;
    spec.width = w;
    spec.height = h;
    spec.bits_per_pixel = 32;
    spec.bytes_per_row = w * 4;
    spec.red_mask = 0x000000ff;
    spec.green_mask = 0x0000ff00;
    spec.blue_mask = 0x00ff0000;
    spec.alpha_mask = 0xff000000;
    spec.red_shift = 0;
    spec.green_shift = 8;
    spec.blue_shift = 16;
    spec.alpha_shift = 24;

    if (output_spec)
      *output_spec = spec;

    if (output_img) {
      image img(spec);
      std::memset(img.data(), 0, spec.bytes_per_row * h);

      CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGContextRef ctx = CGBitmapContextCreate(
        img.data(), w, h, 8, spec.bytes_per_row, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
      CGColorSpaceRelease(cs);
      if (!ctx)
        return false;

      CGContextSetBlendMode(ctx, kCGBlendModeCopy);
      CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
      CGContextRelease(ctx);

      // CoreGraphics only works with premultiplied alpha
      details::divide_rgb_by_alpha(img, true);

      std::swap(*output_img, img);
    }
    return true;
  }

#endif // CLIP_ENABLE_IMAGE

} // anonymous namespace

lock::impl::impl(void*) : m_locked(true) {
  g_pending = nil;
}

lock::impl::~impl() {
  g_pending = nil;
}

bool lock::impl::clear() {
  @autoreleasepool {
    g_pending = nil;
    [UIPasteboard generalPasteboard].items = @[];
    return true;
  }
}

bool lock::impl::is_convertible(format f) const {
  @autoreleasepool {
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];

    if (f == text_format())
      return pasteboard.hasStrings;
#if CLIP_ENABLE_IMAGE
    if (f == image_format())
      return pasteboard.hasImages;
#endif

    NSString* type = format_name(f);
    if (!type)
      return false;
    return [pasteboard containsPasteboardTypes:@[ type ]];
  }
}

bool lock::impl::set_data(format f, const char* buf, size_t len) {
  @autoreleasepool {
    if (f == text_format()) {
      NSString* string = [[NSString alloc] initWithBytes:buf
                                                  length:len
                                                encoding:NSUTF8StringEncoding];
      if (!string)
        return false;
      set_pending_value(kTextType, string);
      return true;
    }

    NSString* type = format_name(f);
    if (!type)
      return false;

    set_pending_value(type, [NSData dataWithBytes:buf length:len]);
    return true;
  }
}

bool lock::impl::get_data(format f, char* buf, size_t len) const {
  @autoreleasepool {
    assert(buf);
    if (!buf || !is_convertible(f))
      return false;

    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];

    if (f == text_format()) {
      NSString* string = pasteboard.string;
      if (!string)
        return false;

      const char* utf8 = string.UTF8String;
      const size_t reqsize = std::strlen(utf8) + 1;
      assert(reqsize <= len);
      if (reqsize > len)
        return false;

      std::memcpy(buf, utf8, reqsize);
      return true;
    }

    NSString* type = format_name(f);
    if (!type)
      return false;

    NSData* data = [pasteboard dataForPasteboardType:type];
    if (!data)
      return false;

    [data getBytes:buf length:std::min<size_t>(len, data.length)];
    return true;
  }
}

size_t lock::impl::get_data_length(format f) const {
  @autoreleasepool {
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];

    if (f == text_format()) {
      NSString* string = pasteboard.string;
      if (!string)
        return 0;
      return std::strlen(string.UTF8String) + 1;
    }

    NSString* type = format_name(f);
    if (!type)
      return 0;

    NSData* data = [pasteboard dataForPasteboardType:type];
    return (data ? data.length : 0);
  }
}

#if CLIP_ENABLE_IMAGE

bool lock::impl::set_image(const image& img) {
  @autoreleasepool {
    const image_spec& spec = img.spec();
    const unsigned long w = spec.width;
    const unsigned long h = spec.height;
    if (w == 0 || h == 0)
      return false;

    if (spec.bits_per_pixel != 32 && spec.bits_per_pixel != 24 && spec.bits_per_pixel != 16)
      return false;

    // Convert the image to straight RGBA
    std::vector<uint8_t> rgba(w * h * 4);
    const int rbits = mask_bits(spec.red_mask);
    const int gbits = mask_bits(spec.green_mask);
    const int bbits = mask_bits(spec.blue_mask);
    const int abits = mask_bits(spec.alpha_mask);
    const int bytes_per_pixel = spec.bits_per_pixel / 8;

    for (unsigned long y = 0; y < h; ++y) {
      const uint8_t* src = (const uint8_t*)img.data() + y * spec.bytes_per_row;
      uint8_t* dst = &rgba[y * w * 4];
      for (unsigned long x = 0; x < w; ++x, src += bytes_per_pixel, dst += 4) {
        uint32_t c = 0;
        std::memcpy(&c, src, bytes_per_pixel);
        dst[0] = scale_component((c & spec.red_mask) >> spec.red_shift, rbits);
        dst[1] = scale_component((c & spec.green_mask) >> spec.green_shift, gbits);
        dst[2] = scale_component((c & spec.blue_mask) >> spec.blue_shift, bbits);
        dst[3] = (spec.alpha_mask ? scale_component((c & spec.alpha_mask) >> spec.alpha_shift, abits) : 255);
      }
    }

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, rgba.data(), rgba.size());
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef cgImage = CGImageCreate(w, h, 8, 32, w * 4, cs,
                                       kCGImageAlphaLast | kCGBitmapByteOrder32Big,
                                       provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    CFRelease(data);
    if (!cgImage)
      return false;

    NSData* png = UIImagePNGRepresentation([UIImage imageWithCGImage:cgImage]);
    CGImageRelease(cgImage);
    if (!png)
      return false;

    set_pending_value(kPngType, png);
    return true;
  }
}

bool lock::impl::get_image(image& img) const {
  @autoreleasepool {
    return get_image_from_pasteboard(&img, nullptr);
  }
}

bool lock::impl::get_image_spec(image_spec& spec) const {
  @autoreleasepool {
    return get_image_from_pasteboard(nullptr, &spec);
  }
}

#endif // CLIP_ENABLE_IMAGE

format register_format(const std::string& name) {
  // Check if the format is already registered
  auto it = g_name_to_format.find(name);
  if (it != g_name_to_format.end())
    return it->second;

  format new_format = g_last_format++;
  g_name_to_format[name] = new_format;
  g_format_to_name[new_format] = name;
  return new_format;
}

} // namespace clip
