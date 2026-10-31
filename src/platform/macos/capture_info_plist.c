/*
 * Hand-wired example build graphs launch bare Mach-O executables and do not
 * have the managed graph's permission-aware plist generation step. Keep the
 * capture usage descriptions in the conventional embedded section so macOS
 * can present consent instead of terminating an example that adopts capture.
 */
#define NATIVE_SDK_CAPTURE_INFO_PLIST                                      \
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"                     \
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "             \
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"              \
    "<plist version=\"1.0\">\n<dict>\n"                                  \
    "  <key>NSMicrophoneUsageDescription</key>\n"                        \
    "  <string>This app captures microphone audio when you start "        \
    "recording.</string>\n"                                               \
    "  <key>NSAudioCaptureUsageDescription</key>\n"                       \
    "  <string>This app captures system audio when you start "            \
    "recording.</string>\n"                                               \
    "  <key>NSScreenCaptureUsageDescription</key>\n"                      \
    "  <string>This app captures system audio when you start "            \
    "recording.</string>\n"                                               \
    "</dict>\n</plist>\n"

__attribute__((used, section("__TEXT,__info_plist")))
static const unsigned char native_sdk_capture_info_plist
    [sizeof(NATIVE_SDK_CAPTURE_INFO_PLIST) - 1] = NATIVE_SDK_CAPTURE_INFO_PLIST;
