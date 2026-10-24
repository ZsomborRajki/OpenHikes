// duo-pose.m — runs *inside* an iPhone Duo simulator, through
// `xcrun simctl spawn`, and moves its hinge or turns it. Built and spawned by
// Scripts/duo-pose.sh; not run on its own.
//
//   duo-pose hinge <degrees>         0 is closed, 180 is open flat
//   duo-pose orientation <value>     portrait | pud | landscape-left |
//                                    landscape-right | faceup | facedown
//
// Neither simctl nor devicectl can fold the Duo, and Device Hub does it only by
// hand. What Device Hub's hinge slider and orientation picker send is a
// vendor-defined HID event — usage page 0xFF61, usage 0x5B — whose payload is a
// binary-serialized dictionary, which the simulator's locationd turns into a
// hinge angle or a device orientation. Posted from inside the simulator, the
// same event does the same thing. That format, and the two private IOKit calls
// below, are not documented by Apple and were verified against Xcode 27.1 and
// the iOS 27.1 runtime; Scripts/duo-pose.sh reads the display state back after
// every change, so a release that breaks them fails there rather than going
// unnoticed.
//
// The event format was first documented by Artem Novichkov's hinge
// (https://github.com/artemnovichkov/hinge, MIT). What follows is the hinge
// and orientation half of duoctl (https://github.com/skarol/duoctl,
// commit efd5e3d), whose licence it is distributed under:
//
//   MIT License
//
//   Copyright (c) 2026 Karolina Samorek
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the "Software"),
//   to deal in the Software without restriction, including without limitation
//   the rights to use, copy, modify, merge, publish, distribute, sublicense,
//   and/or sell copies of the Software, and to permit persons to whom the
//   Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//   DEALINGS IN THE SOFTWARE.

#import <Foundation/Foundation.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, CFDictionaryRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern CFDataRef IOCFSerialize(CFTypeRef, CFOptionFlags);
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t usagePage, uint32_t usage,
    uint32_t version, const uint8_t *data, CFIndex length, uint32_t options);

enum {
    kClientTypeSimple = 4,
    kSerializeBinary = 1,
    kVendorUsagePage = 0xFF61,
    kVendorUsage = 0x5B,
};

static int post(NSString *source, NSString *type, id value) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
    if (!client) {
        fprintf(stderr, "duo-pose: could not create a HID event system client\n");
        return 1;
    }
    NSDictionary *payload = @{
        @"provider": @"com.apple.Virtualization",
        @"source": source,
        @"type": type,
        @"value": value,
    };
    NSData *data = CFBridgingRelease(IOCFSerialize((__bridge CFTypeRef)payload, kSerializeBinary));
    IOHIDEventRef event = data.length > 0
        ? IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), kVendorUsagePage, kVendorUsage, 0,
                                             data.bytes, (CFIndex)data.length, 0)
        : NULL;
    // Both calls are private, so a runtime that changes either may answer
    // NULL. Say so and fail, rather than crash in CFRelease with no word of
    // which half broke.
    if (!event) {
        fprintf(stderr, "duo-pose: could not make the %s event\n", source.UTF8String);
        CFRelease(client);
        return 1;
    }
    IOHIDEventSystemClientDispatchEvent(client, event);
    CFRelease(event);
    // The event system delivers asynchronously, and a process that exits at
    // once can take its last event with it.
    usleep(100000);
    CFRelease(client);
    return 0;
}

static int usage(void) {
    fprintf(stderr,
            "usage: duo-pose hinge <degrees>\n"
            "       duo-pose orientation <portrait|pud|landscape-left|landscape-right|faceup|facedown>\n");
    return 64;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return usage();
        NSString *command = @(argv[1]);
        if ([command isEqualToString:@"hinge"]) {
            double degrees = fmin(fmax(atof(argv[2]), 0), 180);
            return post(@"hinge-slider-control", @"range", @(degrees));
        }
        if ([command isEqualToString:@"orientation"]) {
            NSSet *valid = [NSSet setWithArray:@[ @"portrait", @"pud", @"landscape-left", @"landscape-right",
                                                  @"faceup", @"facedown" ]];
            NSString *value = @(argv[2]);
            if (![valid containsObject:value]) return usage();
            return post(@"orientation-picker-control", @"enum", value);
        }
        return usage();
    }
}
