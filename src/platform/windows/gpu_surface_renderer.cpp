#include "gpu_surface_renderer.h"

#include <d2d1.h>
#include <dwrite_3.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace {

/* Compact binary gpu-surface packet decoding (wire format v5).
 *
 * This independent decoder deliberately repeats the encoder's tags and
 * bounds rather than sharing packed structs across the Zig/C++ ABI. A
 * version or layout disagreement is a refused present, which makes the
 * runtime resynchronize/fall back instead of drawing corrupt content. */
constexpr uint8_t kPacketVersion = 5;
constexpr size_t kRetainedCommandCap = 2048;
constexpr size_t kDirtyRectCap = kWindowsGpuDirtyRectCap;
constexpr uint32_t kMaxSurfacePixels = 8192;
constexpr float kBezierCircle = 0.5522847498307936f;

constexpr uint64_t canvasFontResourceId(uint64_t font_id) {
    /* Zero is DrawText's public default. It and the styled sans variants
     * resolve through the same bundled Geist regular resource the engine's
     * reference metrics use. */
    return font_id == 0 || (font_id >= 3 && font_id <= 6) ? 1 : font_id;
}

constexpr uint64_t canvasFallbackFontResourceId(uint64_t font_id) {
    return font_id == 2 ? 0 : 1;
}

constexpr float canvasStrokeWidth(float width) {
    return width > 0 ? width : 0;
}

static_assert(canvasFontResourceId(0) == 1, "default canvas text uses bundled Geist");
static_assert(canvasFontResourceId(2) == 2, "the built-in mono face keeps its resource id");
static_assert(canvasFontResourceId(6) == 1, "styled sans variants use bundled Geist");
static_assert(canvasFallbackFontResourceId(2) == 0, "mono keeps its platform fallback");
static_assert(canvasFallbackFontResourceId(64) == 1, "missing application fonts fall back to Geist");
static_assert(canvasStrokeWidth(-1.0f) == 0, "negative canvas strokes are empty");
static_assert(canvasStrokeWidth(0.0f) == 0, "zero-width canvas strokes are empty");
static_assert(canvasStrokeWidth(0.5f) == 0.5f, "subpixel canvas strokes keep their width");

template <typename T>
static void releaseCom(T *&value) {
    if (value) value->Release();
    value = nullptr;
}

static float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

static uint64_t gpuClockNs() {
    static LARGE_INTEGER frequency = [] {
        LARGE_INTEGER value = {};
        QueryPerformanceFrequency(&value);
        return value;
    }();
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    const uint64_t ticks_per_second = static_cast<uint64_t>(frequency.QuadPart);
    if (ticks_per_second == 0) return 0;
    const uint64_t ticks = static_cast<uint64_t>(counter.QuadPart);
    return (ticks / ticks_per_second) * 1000000000ULL +
        ((ticks % ticks_per_second) * 1000000000ULL) / ticks_per_second;
}

struct Point {
    float x = 0;
    float y = 0;
};

struct Rect {
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
};

struct Radius {
    float top_left = 0;
    float top_right = 0;
    float bottom_right = 0;
    float bottom_left = 0;
};

struct Color {
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 1;
};

struct Affine {
    float a = 1;
    float b = 0;
    float c = 0;
    float d = 1;
    float tx = 0;
    float ty = 0;
};

constexpr float maxTransformAxisLengthSquared(const Affine &matrix) {
    const float x_scale_squared = matrix.a * matrix.a + matrix.b * matrix.b;
    const float y_scale_squared = matrix.c * matrix.c + matrix.d * matrix.d;
    return x_scale_squared > y_scale_squared ? x_scale_squared : y_scale_squared;
}

static float transformScale(const Affine &matrix) {
    return std::max(0.0001f, std::sqrt(maxTransformAxisLengthSquared(matrix)));
}

static_assert(maxTransformAxisLengthSquared(Affine{2, 0, 0, 2, 0, 0}) == 4,
    "uniform command scaling must scale effect kernels");
static_assert(maxTransformAxisLengthSquared(Affine{0, 3, -2, 0, 0, 0}) == 9,
    "rotated nonuniform transforms use their largest axis scale");

static Rect normalized(Rect rect) {
    if (rect.width < 0) {
        rect.x += rect.width;
        rect.width = -rect.width;
    }
    if (rect.height < 0) {
        rect.y += rect.height;
        rect.height = -rect.height;
    }
    return rect;
}

static bool empty(Rect rect) {
    rect = normalized(rect);
    return rect.width <= 0 || rect.height <= 0;
}

static bool intersects(Rect left, Rect right) {
    left = normalized(left);
    right = normalized(right);
    return left.x < right.x + right.width && right.x < left.x + left.width &&
        left.y < right.y + right.height && right.y < left.y + left.height;
}

static Rect intersection(Rect left, Rect right) {
    left = normalized(left);
    right = normalized(right);
    const float x0 = std::max(left.x, right.x);
    const float y0 = std::max(left.y, right.y);
    const float x1 = std::min(left.x + left.width, right.x + right.width);
    const float y1 = std::min(left.y + left.height, right.y + right.height);
    return {x0, y0, std::max(0.0f, x1 - x0), std::max(0.0f, y1 - y0)};
}

static bool contains(Rect rect, double x, double y) {
    rect = normalized(rect);
    return x >= rect.x && y >= rect.y && x < rect.x + rect.width && y < rect.y + rect.height;
}

static D2D1_RECT_F d2dRect(Rect rect) {
    rect = normalized(rect);
    return D2D1::RectF(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
}

static Rect transformedRect(Rect rect, const Affine &matrix) {
    rect = normalized(rect);
    const Point corners[4] = {
        {rect.x, rect.y},
        {rect.x + rect.width, rect.y},
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
    };
    float x0 = std::numeric_limits<float>::infinity();
    float y0 = std::numeric_limits<float>::infinity();
    float x1 = -std::numeric_limits<float>::infinity();
    float y1 = -std::numeric_limits<float>::infinity();
    for (const Point &point : corners) {
        const float x = point.x * matrix.a + point.y * matrix.c + matrix.tx;
        const float y = point.x * matrix.b + point.y * matrix.d + matrix.ty;
        x0 = std::min(x0, x);
        y0 = std::min(y0, y);
        x1 = std::max(x1, x);
        y1 = std::max(y1, y);
    }
    return {x0, y0, x1 - x0, y1 - y0};
}

static D2D1_COLOR_F d2dColor(Color color, float opacity = 1.0f) {
    return D2D1::ColorF(clamp01(color.r), clamp01(color.g), clamp01(color.b), clamp01(color.a * opacity));
}

static uint32_t packedColor(Color color) {
    const uint32_t r = static_cast<uint32_t>(std::lround(clamp01(color.r) * 255.0f));
    const uint32_t g = static_cast<uint32_t>(std::lround(clamp01(color.g) * 255.0f));
    const uint32_t b = static_cast<uint32_t>(std::lround(clamp01(color.b) * 255.0f));
    const uint32_t a = static_cast<uint32_t>(std::lround(clamp01(color.a) * 255.0f));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

class Reader {
public:
    Reader(const uint8_t *bytes, size_t length) : bytes_(bytes), length_(length) {}

    bool failed() const { return failed_; }
    bool finished() const { return !failed_ && offset_ == length_; }
    size_t remaining() const { return offset_ <= length_ ? length_ - offset_ : 0; }

    bool bytes(void *destination, size_t count) {
        if (!has(count)) return false;
        if (count) std::memcpy(destination, bytes_ + offset_, count);
        offset_ += count;
        return true;
    }

    uint8_t u8() {
        uint8_t value = 0;
        bytes(&value, sizeof(value));
        return value;
    }

    uint16_t u16() {
        uint8_t raw[2] = {};
        if (!bytes(raw, sizeof(raw))) return 0;
        return static_cast<uint16_t>(raw[0]) |
            static_cast<uint16_t>(static_cast<uint16_t>(raw[1]) << 8);
    }

    uint32_t u32() {
        uint8_t raw[4] = {};
        if (!bytes(raw, sizeof(raw))) return 0;
        return static_cast<uint32_t>(raw[0]) |
            (static_cast<uint32_t>(raw[1]) << 8) |
            (static_cast<uint32_t>(raw[2]) << 16) |
            (static_cast<uint32_t>(raw[3]) << 24);
    }

    uint64_t u64() {
        uint8_t raw[8] = {};
        if (!bytes(raw, sizeof(raw))) return 0;
        uint64_t value = 0;
        for (unsigned index = 0; index < 8; ++index) value |= static_cast<uint64_t>(raw[index]) << (index * 8);
        return value;
    }

    float f32() {
        const uint32_t bits = u32();
        float value = 0;
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value)) failed_ = true;
        return value;
    }

    std::string string() {
        const uint32_t count = u32();
        if (!has(count)) return {};
        std::string value(reinterpret_cast<const char *>(bytes_ + offset_), count);
        offset_ += count;
        return value;
    }

    void fail() { failed_ = true; }

private:
    bool has(size_t count) {
        if (failed_ || count > remaining()) {
            failed_ = true;
            return false;
        }
        return true;
    }

    const uint8_t *bytes_ = nullptr;
    size_t length_ = 0;
    size_t offset_ = 0;
    bool failed_ = false;
};

static Point readPoint(Reader &reader) {
    return {reader.f32(), reader.f32()};
}

static Rect readRect(Reader &reader) {
    return {reader.f32(), reader.f32(), reader.f32(), reader.f32()};
}

static Radius readRadius(Reader &reader) {
    return {reader.f32(), reader.f32(), reader.f32(), reader.f32()};
}

static Color readColor(Reader &reader) {
    return {reader.f32(), reader.f32(), reader.f32(), reader.f32()};
}

struct PathElement {
    enum class Verb : uint8_t { move, line, quadratic, cubic, close };
    Verb verb = Verb::move;
    Point points[3] = {};
};

struct Shape {
    enum class Kind : uint8_t { none, rect, rounded_rect, stroke_rect, line, path };
    Kind kind = Kind::none;
    Rect rect = {};
    Radius radius = {};
    Point from = {};
    Point to = {};
    float width = 1;
    std::vector<PathElement> path;
};

struct GradientStop {
    float offset = 0;
    Color color = {};
};

struct Paint {
    enum class Kind : uint8_t { none, color, linear_gradient };
    Kind kind = Kind::none;
    Color color = {};
    Point start = {};
    Point end = {};
    std::vector<GradientStop> stops;
};

struct ImageCommand {
    uint64_t id = 0;
    bool has_src = false;
    Rect src = {};
    Rect dst = {};
    float opacity = 1;
    uint8_t fit = 0;
    uint8_t sampling = 1;
    Radius radius = {};
};

struct TextLine {
    float x = 0;
    float baseline = 0;
    std::string text;
};

struct PositionedGlyph {
    uint16_t id = 0;
    uint64_t font_id = 0;
    float x = 0;
    float baseline = 0;
    float advance = 0;
};

struct PositionedTextFragment {
    float x = 0;
    float baseline = 0;
    std::string text;
};

struct TextCommand {
    uint64_t font_id = 0;
    float size = 12;
    Point origin = {};
    Color color = {};
    std::string text;
    bool has_positioned_glyphs = false;
    std::vector<PositionedGlyph> positioned_glyphs;
    std::vector<PositionedTextFragment> positioned_fragments;
    bool has_layout = false;
    float max_width = 0;
    float line_height = 0;
    uint8_t wrap = 1;
    uint8_t align = 0;
    bool has_lines = false;
    std::vector<TextLine> lines;
};

struct Effect {
    enum class Kind : uint8_t { none, shadow, blur };
    Kind kind = Kind::none;
    Rect rect = {};
    Radius radius = {};
    Point offset = {};
    float blur = 0;
    float spread = 0;
    Color color = {};
};

struct Command {
    uint8_t kind = 0xff;
    Rect bounds = {};
    float opacity = 1;
    float stroke_width = 1;
    uint8_t cap = 0;
    bool has_id = false;
    uint64_t id = 0;
    bool has_clip = false;
    Rect clip = {};
    bool has_transform = false;
    Affine transform = {};
    Shape shape;
    Paint paint;
    ImageCommand image;
    TextCommand text;
    Effect effect;
};

struct KeyedCommand {
    uint64_t key = 0;
    Command command;
};

struct ImageMeta {
    uint64_t id = 0;
    uint64_t fingerprint = 0;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct ImageAction {
    uint8_t kind = 0;
    uint64_t id = 0;
    uint64_t fingerprint = 0;
    uint32_t image_index = UINT32_MAX;
};

struct DecodedPacket {
    uint8_t load_action = 0;
    uint64_t generation = 0;
    bool has_scissor = false;
    Rect scissor = {};
    std::vector<Rect> dirty_rects;
    std::vector<ImageMeta> images;
    std::vector<ImageAction> image_actions;
    std::vector<KeyedCommand> commands;
    std::vector<uint64_t> evicts;
    std::vector<KeyedCommand> upserts;
    std::vector<uint64_t> order;
};

static bool readShape(Reader &reader, Shape *shape) {
    switch (reader.u8()) {
        case 1:
            shape->kind = Shape::Kind::rect;
            shape->rect = readRect(reader);
            break;
        case 2:
            shape->kind = Shape::Kind::rounded_rect;
            shape->rect = readRect(reader);
            shape->radius = readRadius(reader);
            break;
        case 3:
            shape->kind = Shape::Kind::stroke_rect;
            shape->rect = readRect(reader);
            shape->radius = readRadius(reader);
            shape->width = reader.f32();
            break;
        case 4:
            shape->kind = Shape::Kind::line;
            shape->from = readPoint(reader);
            shape->to = readPoint(reader);
            shape->width = reader.f32();
            break;
        case 5: {
            shape->kind = Shape::Kind::path;
            const uint32_t count = reader.u32();
            if (reader.failed() || count > reader.remaining() || count > 65536) return false;
            shape->path.reserve(count);
            for (uint32_t index = 0; index < count; ++index) {
                PathElement element;
                const uint8_t verb = reader.u8();
                if (verb > 4) return false;
                element.verb = static_cast<PathElement::Verb>(verb);
                const size_t point_count = verb <= 1 ? 1 : (verb == 2 ? 2 : (verb == 3 ? 3 : 0));
                for (size_t point = 0; point < point_count; ++point) element.points[point] = readPoint(reader);
                shape->path.push_back(element);
            }
            break;
        }
        default:
            return false;
    }
    return !reader.failed();
}

static bool readPaint(Reader &reader, Paint *paint) {
    switch (reader.u8()) {
        case 1:
            paint->kind = Paint::Kind::color;
            paint->color = readColor(reader);
            break;
        case 2: {
            paint->kind = Paint::Kind::linear_gradient;
            paint->start = readPoint(reader);
            paint->end = readPoint(reader);
            const uint32_t count = reader.u32();
            if (reader.failed() || count > reader.remaining() || count > 4096) return false;
            paint->stops.reserve(count);
            for (uint32_t index = 0; index < count; ++index) {
                GradientStop stop;
                stop.offset = reader.f32();
                stop.color = readColor(reader);
                paint->stops.push_back(stop);
            }
            if (paint->stops.empty()) return false;
            break;
        }
        default:
            return false;
    }
    return !reader.failed();
}

static bool readImage(Reader &reader, ImageCommand *image) {
    image->id = reader.u64();
    image->has_src = reader.u8() != 0;
    if (image->has_src) image->src = readRect(reader);
    image->dst = readRect(reader);
    image->opacity = reader.f32();
    image->fit = reader.u8();
    image->sampling = reader.u8();
    image->radius = readRadius(reader);
    return !reader.failed() && image->id != 0 && image->fit <= 2 && image->sampling <= 1;
}

static bool readText(Reader &reader, TextCommand *text) {
    text->font_id = reader.u64();
    text->size = reader.f32();
    text->origin = readPoint(reader);
    text->color = readColor(reader);
    text->text = reader.string();
    text->has_positioned_glyphs = reader.u8() != 0;
    if (text->has_positioned_glyphs) {
        const uint32_t glyph_count = reader.u32();
        /* Every glyph consumes at least id u16 + flags u8 + three f32s;
         * font overrides add u64. Bound both allocation and framing. */
        if (reader.failed() || glyph_count > 65536 || glyph_count > reader.remaining() / 15) return false;
        text->positioned_glyphs.reserve(glyph_count);
        for (uint32_t index = 0; index < glyph_count; ++index) {
            PositionedGlyph glyph;
            glyph.id = reader.u16();
            const uint8_t flags = reader.u8();
            if (flags > 1) return false;
            glyph.font_id = (flags & 1) != 0 ? reader.u64() : text->font_id;
            glyph.x = reader.f32();
            glyph.baseline = reader.f32();
            glyph.advance = reader.f32();
            text->positioned_glyphs.push_back(glyph);
        }
        const uint32_t fragment_count = reader.u32();
        if (reader.failed() || fragment_count > 64 || fragment_count > reader.remaining() / 12) return false;
        text->positioned_fragments.reserve(fragment_count);
        for (uint32_t index = 0; index < fragment_count; ++index) {
            PositionedTextFragment fragment;
            fragment.x = reader.f32();
            fragment.baseline = reader.f32();
            fragment.text = reader.string();
            text->positioned_fragments.push_back(std::move(fragment));
        }
    }
    text->has_layout = reader.u8() != 0;
    if (!text->has_layout) return !reader.failed();
    text->max_width = reader.f32();
    text->line_height = reader.f32();
    text->wrap = reader.u8();
    text->align = reader.u8();
    if (text->wrap > 2 || text->align > 2) return false;
    text->has_lines = reader.u8() != 0;
    if (!text->has_lines) return !reader.failed();
    const uint32_t count = reader.u32();
    if (reader.failed() || count > reader.remaining() || count > 4096) return false;
    text->lines.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        TextLine line;
        line.x = reader.f32();
        line.baseline = reader.f32();
        line.text = reader.string();
        text->lines.push_back(std::move(line));
    }
    return !reader.failed();
}

static bool readEffect(Reader &reader, Effect *effect) {
    switch (reader.u8()) {
        case 1:
            effect->kind = Effect::Kind::shadow;
            effect->rect = readRect(reader);
            effect->radius = readRadius(reader);
            effect->offset = readPoint(reader);
            effect->blur = reader.f32();
            effect->spread = reader.f32();
            effect->color = readColor(reader);
            break;
        case 2:
            effect->kind = Effect::Kind::blur;
            effect->rect = readRect(reader);
            effect->blur = reader.f32();
            break;
        default:
            return false;
    }
    return !reader.failed();
}

enum : uint8_t {
    kCommandFlagId = 0x01,
    kCommandFlagClip = 0x02,
    kCommandFlagTransform = 0x04,
    kCommandFlagShape = 0x08,
    kCommandFlagPaint = 0x10,
    kCommandFlagImage = 0x20,
    kCommandFlagText = 0x40,
    kCommandFlagEffect = 0x80,
};

static bool readCommand(Reader &reader, Command *command) {
    command->kind = reader.u8();
    const uint8_t flags = reader.u8();
    command->bounds = readRect(reader);
    command->opacity = reader.f32();
    command->stroke_width = reader.f32();
    command->cap = reader.u8();
    if (reader.failed() || command->kind > 13 || command->cap > 1) return false;
    if (flags & kCommandFlagId) {
        command->has_id = true;
        command->id = reader.u64();
    }
    if (flags & kCommandFlagClip) {
        command->has_clip = true;
        command->clip = readRect(reader);
    }
    if (flags & kCommandFlagTransform) {
        command->has_transform = true;
        command->transform = {reader.f32(), reader.f32(), reader.f32(), reader.f32(), reader.f32(), reader.f32()};
    }
    if ((flags & kCommandFlagShape) && !readShape(reader, &command->shape)) return false;
    if ((flags & kCommandFlagPaint) && !readPaint(reader, &command->paint)) return false;
    if ((flags & kCommandFlagImage) && !readImage(reader, &command->image)) return false;
    if ((flags & kCommandFlagText) && !readText(reader, &command->text)) return false;
    if ((flags & kCommandFlagEffect) && !readEffect(reader, &command->effect)) return false;
    if (reader.failed()) return false;

    /* Treat the packet as an untrusted ABI boundary even though today's
     * producer lives in the same process. Every command kind has one
     * exact payload shape; accepting unrelated optional sections would
     * let a corrupt packet advance the reader successfully but silently
     * draw a different command than the bytes describe. */
    const uint8_t payload_flags = flags &
        (kCommandFlagShape | kCommandFlagPaint | kCommandFlagImage | kCommandFlagText | kCommandFlagEffect);
    switch (command->kind) {
        case 0:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rect && command->paint.kind == Paint::Kind::color;
        case 1:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rect && command->paint.kind == Paint::Kind::linear_gradient;
        case 2:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rounded_rect && command->paint.kind == Paint::Kind::color;
        case 3:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::rounded_rect && command->paint.kind == Paint::Kind::linear_gradient;
        case 4:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::stroke_rect && command->paint.kind == Paint::Kind::color;
        case 5:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::stroke_rect && command->paint.kind == Paint::Kind::linear_gradient;
        case 6:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::line && command->paint.kind == Paint::Kind::color;
        case 7:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::line && command->paint.kind == Paint::Kind::linear_gradient;
        case 8: case 9:
            return payload_flags == (kCommandFlagShape | kCommandFlagPaint) &&
                command->shape.kind == Shape::Kind::path && command->paint.kind != Paint::Kind::none;
        case 10:
            return payload_flags == kCommandFlagImage && command->image.id != 0;
        case 11:
            /* The shared model keeps the text color both in the text
             * payload and in its resource paint metadata, so both
             * sections intentionally ride the canonical wire packet. */
            return payload_flags == (kCommandFlagPaint | kCommandFlagText) &&
                command->paint.kind == Paint::Kind::color;
        case 12:
            return payload_flags == kCommandFlagEffect && command->effect.kind == Effect::Kind::shadow;
        case 13:
            return payload_flags == kCommandFlagEffect && command->effect.kind == Effect::Kind::blur;
        default:
            return false;
    }
}

static bool readKeyedCommands(Reader &reader, std::vector<KeyedCommand> *commands, uint32_t count) {
    if (reader.failed() || count > kRetainedCommandCap || count > reader.remaining()) return false;
    commands->reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        KeyedCommand keyed;
        keyed.key = reader.u64();
        if (!readCommand(reader, &keyed.command)) return false;
        commands->push_back(std::move(keyed));
    }
    return true;
}

static bool decodePacket(const uint8_t *bytes, size_t length, DecodedPacket *packet) {
    if (!bytes || length < 16 || std::memcmp(bytes, "NSGP", 4) != 0) return false;
    Reader reader(bytes, length);
    uint8_t magic[4] = {};
    if (!reader.bytes(magic, sizeof(magic)) || reader.u8() != kPacketVersion) return false;
    packet->load_action = reader.u8();
    const uint8_t flags = reader.u8();
    (void)reader.u8();
    packet->generation = reader.u64();
    if (packet->load_action < 1 || packet->load_action > 3 || (flags & ~0x03u) != 0) return false;

    packet->has_scissor = (flags & 0x01) != 0;
    if (packet->has_scissor) packet->scissor = readRect(reader);
    if (flags & 0x02) {
        if (!packet->has_scissor) return false;
        const uint32_t count = reader.u32();
        if (reader.failed() || count == 0 || count > kDirtyRectCap) return false;
        packet->dirty_rects.reserve(count);
        for (uint32_t index = 0; index < count; ++index) packet->dirty_rects.push_back(readRect(reader));
    }

    const uint32_t image_count = reader.u32();
    if (reader.failed() || image_count > reader.remaining() || image_count > 65536) return false;
    packet->images.reserve(image_count);
    for (uint32_t index = 0; index < image_count; ++index) {
        ImageMeta image;
        image.id = reader.u64();
        image.fingerprint = reader.u64();
        image.width = reader.u32();
        image.height = reader.u32();
        packet->images.push_back(image);
    }

    const uint32_t action_count = reader.u32();
    if (reader.failed() || action_count > reader.remaining() || action_count > 65536) return false;
    packet->image_actions.reserve(action_count);
    for (uint32_t index = 0; index < action_count; ++index) {
        ImageAction action;
        action.kind = reader.u8();
        action.id = reader.u64();
        action.fingerprint = reader.u64();
        action.image_index = reader.u32();
        if (action.kind > 2) return false;
        packet->image_actions.push_back(action);
    }

    if (packet->load_action == 3) {
        const uint32_t evict_count = reader.u32();
        if (reader.failed() || evict_count > kRetainedCommandCap || evict_count > reader.remaining()) return false;
        packet->evicts.reserve(evict_count);
        for (uint32_t index = 0; index < evict_count; ++index) packet->evicts.push_back(reader.u64());

        const uint32_t upsert_count = reader.u32();
        if (!readKeyedCommands(reader, &packet->upserts, upsert_count)) return false;

        const uint32_t order_count = reader.u32();
        if (reader.failed() || order_count > kRetainedCommandCap || order_count > reader.remaining()) return false;
        packet->order.reserve(order_count);
        for (uint32_t index = 0; index < order_count; ++index) packet->order.push_back(reader.u64());
    } else {
        const uint32_t command_count = reader.u32();
        if (!readKeyedCommands(reader, &packet->commands, command_count)) return false;
    }
    return reader.finished();
}

struct ImageResource {
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t serial = 0;
    /* Direct2D's native 32-bit format: premultiplied BGRA, top-down. */
    std::vector<uint8_t> bgra;
};

constexpr bool imageActionResolvesResource(uint8_t kind) {
    return kind == 0 || kind == 1; /* upload or retain */
}

constexpr bool imageMetadataMatchesResource(
    bool resource_present,
    uint32_t metadata_width,
    uint32_t metadata_height,
    uint32_t resource_width,
    uint32_t resource_height
) {
    /* The renderer-wide store is authoritative. An absent entry is the
     * legitimate "not registered (yet/anymore)" state and draws nothing,
     * even though its packet metadata is therefore 0x0. */
    return !resource_present ||
        (metadata_width != 0 && metadata_height != 0 &&
            metadata_width == resource_width && metadata_height == resource_height);
}

static_assert(imageActionResolvesResource(0), "image uploads resolve the renderer-wide store");
static_assert(imageActionResolvesResource(1), "image retains reconcile the renderer-wide store");
static_assert(!imageActionResolvesResource(2), "image evictions only remove surface state");
static_assert(imageMetadataMatchesResource(false, 0, 0, 0, 0),
    "an unregistered image is a valid transient packet resource");
static_assert(imageMetadataMatchesResource(true, 64, 32, 64, 32),
    "a registered image must match its packet metadata");
static_assert(!imageMetadataMatchesResource(true, 64, 32, 32, 64),
    "mismatched registered-image metadata is rejected");

class FontBytesOwner final : public IUnknown {
public:
    explicit FontBytesOwner(const uint8_t *bytes, size_t length) : bytes_(bytes, bytes + length) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid == __uuidof(IUnknown)) {
            *object = static_cast<IUnknown *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG refs = --refs_;
        if (refs == 0) delete this;
        return refs;
    }

    const void *data() const { return bytes_.data(); }
    UINT32 size() const { return static_cast<UINT32>(bytes_.size()); }

private:
    std::atomic<ULONG> refs_{1};
    std::vector<uint8_t> bytes_;
};

struct FontResource {
    uint64_t token = 0;
    FontBytesOwner *owner = nullptr;
    IDWriteFontFile *file = nullptr;
    IDWriteFontCollection1 *collection = nullptr;
    std::wstring family;

    ~FontResource() {
        releaseCom(collection);
        releaseCom(file);
        releaseCom(owner);
    }
};

class GpuSurfaceImpl;

class GpuRendererImpl final : public WindowsGpuRenderer, public std::enable_shared_from_this<GpuRendererImpl> {
public:
    GpuRendererImpl() = default;
    ~GpuRendererImpl() override {
        fonts_.clear();
        images_.clear();
        releaseCom(font_fallback_);
        if (dwrite_factory_ && memory_font_loader_) dwrite_factory_->UnregisterFontFileLoader(memory_font_loader_);
        releaseCom(memory_font_loader_);
        releaseCom(dwrite_factory5_);
        releaseCom(dwrite_factory_);
        releaseCom(d2d_factory_);
    }

    bool initialize() {
        D2D1_FACTORY_OPTIONS options = {};
        if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, options, &d2d_factory_))) return false;
        IUnknown *unknown = nullptr;
        if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), &unknown)) || !unknown) return false;
        dwrite_factory_ = static_cast<IDWriteFactory *>(unknown);
        if (FAILED(dwrite_factory_->QueryInterface(__uuidof(IDWriteFactory5), reinterpret_cast<void **>(&dwrite_factory5_))) ||
            !dwrite_factory5_) return false;
        if (FAILED(dwrite_factory5_->CreateInMemoryFontFileLoader(&memory_font_loader_)) ||
            !memory_font_loader_) return false;
        if (FAILED(dwrite_factory_->RegisterFontFileLoader(memory_font_loader_))) return false;

        /* Text layout is planned against one explicit face and the engine's
         * deterministic .notdef advance. An empty custom fallback prevents
         * IDWriteTextLayout from silently substituting machine fonts for
         * missing glyphs; every created layout installs this object below. */
        IDWriteFontFallbackBuilder *fallback_builder = nullptr;
        HRESULT fallback_result = dwrite_factory5_->CreateFontFallbackBuilder(&fallback_builder);
        if (SUCCEEDED(fallback_result) && fallback_builder) {
            fallback_result = fallback_builder->CreateFontFallback(&font_fallback_);
        }
        releaseCom(fallback_builder);
        return SUCCEEDED(fallback_result) && font_fallback_;
    }

    std::shared_ptr<WindowsGpuSurface> createSurface(HWND hwnd) override;

    bool uploadImage(uint64_t id, uint32_t width, uint32_t height, const uint8_t *rgba, size_t rgba_len) override {
        if (id == 0 || width == 0 || height == 0 || !rgba) return false;
        const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
        if (pixels > std::numeric_limits<size_t>::max() / 4 || rgba_len != pixels * 4) return false;
        auto resource = std::make_shared<ImageResource>();
        resource->width = width;
        resource->height = height;
        resource->serial = next_resource_serial_++;
        resource->bgra.resize(rgba_len);
        for (size_t index = 0; index < pixels; ++index) {
            const uint8_t *source = rgba + index * 4;
            uint8_t *destination = resource->bgra.data() + index * 4;
            const uint32_t alpha = source[3];
            destination[0] = static_cast<uint8_t>((static_cast<uint32_t>(source[2]) * alpha + 127) / 255);
            destination[1] = static_cast<uint8_t>((static_cast<uint32_t>(source[1]) * alpha + 127) / 255);
            destination[2] = static_cast<uint8_t>((static_cast<uint32_t>(source[0]) * alpha + 127) / 255);
            destination[3] = source[3];
        }
        images_[id] = std::move(resource);
        return true;
    }

    bool removeImage(uint64_t id) override {
        if (id == 0) return false;
        images_.erase(id);
        return true;
    }

    bool registerFont(uint64_t id, const uint8_t *ttf, size_t ttf_len, uint64_t *token) override {
        if (!token || id == 0 || !ttf || ttf_len == 0 || ttf_len > UINT32_MAX ||
            !dwrite_factory5_ || !memory_font_loader_) return false;

        auto resource = std::make_shared<FontResource>();
        resource->owner = new (std::nothrow) FontBytesOwner(ttf, ttf_len);
        if (!resource->owner) return false;
        if (FAILED(memory_font_loader_->CreateInMemoryFontFileReference(
                dwrite_factory_, resource->owner->data(), resource->owner->size(), resource->owner, &resource->file)) || !resource->file) {
            return false;
        }

        IDWriteFontSetBuilder1 *builder = nullptr;
        IDWriteFontSet *font_set = nullptr;
        HRESULT result = dwrite_factory5_->CreateFontSetBuilder(&builder);
        if (SUCCEEDED(result)) result = builder->AddFontFile(resource->file);
        if (SUCCEEDED(result)) result = builder->CreateFontSet(&font_set);
        if (SUCCEEDED(result)) result = dwrite_factory5_->CreateFontCollectionFromFontSet(font_set, &resource->collection);
        releaseCom(font_set);
        releaseCom(builder);
        if (FAILED(result) || !resource->collection || resource->collection->GetFontFamilyCount() == 0) return false;

        IDWriteFontFamily1 *family = nullptr;
        IDWriteLocalizedStrings *names = nullptr;
        result = resource->collection->GetFontFamily(0, &family);
        if (SUCCEEDED(result)) result = family->GetFamilyNames(&names);
        UINT32 length = 0;
        if (SUCCEEDED(result)) result = names->GetStringLength(0, &length);
        if (SUCCEEDED(result)) {
            resource->family.resize(static_cast<size_t>(length) + 1);
            result = names->GetString(0, resource->family.data(), length + 1);
            if (SUCCEEDED(result)) resource->family.resize(length);
        }
        releaseCom(names);
        releaseCom(family);
        if (FAILED(result) || resource->family.empty()) return false;

        resource->token = next_font_token_++;
        if (resource->token == 0) resource->token = next_font_token_++;
        fonts_[id] = resource;
        *token = resource->token;
        return true;
    }

    bool unregisterFont(uint64_t id, uint64_t token) override {
        auto found = fonts_.find(id);
        if (found != fonts_.end() && found->second->token == token) fonts_.erase(found);
        return true;
    }

    ID2D1Factory *d2dFactory() const { return d2d_factory_; }
    IDWriteFactory *dwriteFactory() const { return dwrite_factory_; }
    IDWriteFontFallback *fontFallback() const { return font_fallback_; }

    std::shared_ptr<ImageResource> image(uint64_t id) const {
        auto found = images_.find(id);
        return found == images_.end() ? nullptr : found->second;
    }

    std::shared_ptr<FontResource> font(uint64_t id) const {
        auto found = fonts_.find(id);
        return found == fonts_.end() ? nullptr : found->second;
    }

private:
    ID2D1Factory *d2d_factory_ = nullptr;
    IDWriteFactory *dwrite_factory_ = nullptr;
    IDWriteFactory5 *dwrite_factory5_ = nullptr;
    IDWriteInMemoryFontFileLoader *memory_font_loader_ = nullptr;
    IDWriteFontFallback *font_fallback_ = nullptr;
    std::map<uint64_t, std::shared_ptr<ImageResource>> images_;
    std::map<uint64_t, std::shared_ptr<FontResource>> fonts_;
    uint64_t next_resource_serial_ = 1;
    uint64_t next_font_token_ = 1;
};

static bool makeRoundedGeometry(ID2D1Factory *factory, Rect input, Radius input_radius, ID2D1PathGeometry **geometry) {
    if (!factory || !geometry) return false;
    *geometry = nullptr;
    const Rect rect = normalized(input);
    const float limit = std::max(0.0f, std::min(rect.width, rect.height) * 0.5f);
    const float tl = std::max(0.0f, std::min(limit, input_radius.top_left));
    const float tr = std::max(0.0f, std::min(limit, input_radius.top_right));
    const float br = std::max(0.0f, std::min(limit, input_radius.bottom_right));
    const float bl = std::max(0.0f, std::min(limit, input_radius.bottom_left));
    ID2D1PathGeometry *path = nullptr;
    ID2D1GeometrySink *sink = nullptr;
    HRESULT result = factory->CreatePathGeometry(&path);
    if (SUCCEEDED(result)) result = path->Open(&sink);
    if (FAILED(result) || !sink) {
        releaseCom(sink);
        releaseCom(path);
        return false;
    }

    const float x0 = rect.x;
    const float y0 = rect.y;
    const float x1 = rect.x + rect.width;
    const float y1 = rect.y + rect.height;
    sink->BeginFigure(D2D1::Point2F(x0 + tl, y0), D2D1_FIGURE_BEGIN_FILLED);
    sink->AddLine(D2D1::Point2F(x1 - tr, y0));
    if (tr > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x1 - tr + tr * kBezierCircle, y0),
        D2D1::Point2F(x1, y0 + tr - tr * kBezierCircle),
        D2D1::Point2F(x1, y0 + tr)));
    else sink->AddLine(D2D1::Point2F(x1, y0));
    sink->AddLine(D2D1::Point2F(x1, y1 - br));
    if (br > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x1, y1 - br + br * kBezierCircle),
        D2D1::Point2F(x1 - br + br * kBezierCircle, y1),
        D2D1::Point2F(x1 - br, y1)));
    else sink->AddLine(D2D1::Point2F(x1, y1));
    sink->AddLine(D2D1::Point2F(x0 + bl, y1));
    if (bl > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x0 + bl - bl * kBezierCircle, y1),
        D2D1::Point2F(x0, y1 - bl + bl * kBezierCircle),
        D2D1::Point2F(x0, y1 - bl)));
    else sink->AddLine(D2D1::Point2F(x0, y1));
    sink->AddLine(D2D1::Point2F(x0, y0 + tl));
    if (tl > 0) sink->AddBezier(D2D1::BezierSegment(
        D2D1::Point2F(x0, y0 + tl - tl * kBezierCircle),
        D2D1::Point2F(x0 + tl - tl * kBezierCircle, y0),
        D2D1::Point2F(x0 + tl, y0)));
    else sink->AddLine(D2D1::Point2F(x0, y0));
    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    result = sink->Close();
    releaseCom(sink);
    if (FAILED(result)) {
        releaseCom(path);
        return false;
    }
    *geometry = path;
    return true;
}

static bool makePathGeometry(ID2D1Factory *factory, const Shape &shape, bool filled, ID2D1PathGeometry **geometry) {
    if (!factory || !geometry || shape.kind != Shape::Kind::path) return false;
    *geometry = nullptr;
    ID2D1PathGeometry *path = nullptr;
    ID2D1GeometrySink *sink = nullptr;
    HRESULT result = factory->CreatePathGeometry(&path);
    if (SUCCEEDED(result)) result = path->Open(&sink);
    if (FAILED(result) || !sink) {
        releaseCom(sink);
        releaseCom(path);
        return false;
    }
    bool figure_open = false;
    for (const PathElement &element : shape.path) {
        switch (element.verb) {
            case PathElement::Verb::move:
                if (figure_open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
                sink->BeginFigure(D2D1::Point2F(element.points[0].x, element.points[0].y),
                    filled ? D2D1_FIGURE_BEGIN_FILLED : D2D1_FIGURE_BEGIN_HOLLOW);
                figure_open = true;
                break;
            case PathElement::Verb::line:
                if (!figure_open) { result = E_INVALIDARG; }
                else sink->AddLine(D2D1::Point2F(element.points[0].x, element.points[0].y));
                break;
            case PathElement::Verb::quadratic:
                if (!figure_open) { result = E_INVALIDARG; }
                else sink->AddQuadraticBezier(D2D1::QuadraticBezierSegment(
                    D2D1::Point2F(element.points[0].x, element.points[0].y),
                    D2D1::Point2F(element.points[1].x, element.points[1].y)));
                break;
            case PathElement::Verb::cubic:
                if (!figure_open) { result = E_INVALIDARG; }
                else sink->AddBezier(D2D1::BezierSegment(
                    D2D1::Point2F(element.points[0].x, element.points[0].y),
                    D2D1::Point2F(element.points[1].x, element.points[1].y),
                    D2D1::Point2F(element.points[2].x, element.points[2].y)));
                break;
            case PathElement::Verb::close:
                if (!figure_open) { result = E_INVALIDARG; }
                else {
                    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
                    figure_open = false;
                }
                break;
        }
        if (FAILED(result)) break;
    }
    if (figure_open) sink->EndFigure(D2D1_FIGURE_END_OPEN);
    if (SUCCEEDED(result)) result = sink->Close();
    releaseCom(sink);
    if (FAILED(result)) {
        releaseCom(path);
        return false;
    }
    *geometry = path;
    return true;
}

class GpuSurfaceImpl final : public WindowsGpuSurface {
public:
    GpuSurfaceImpl(std::shared_ptr<GpuRendererImpl> renderer, HWND hwnd) : renderer_(std::move(renderer)), hwnd_(hwnd) {
        D2D1_STROKE_STYLE_PROPERTIES style = D2D1::StrokeStyleProperties();
        style.startCap = D2D1_CAP_STYLE_FLAT;
        style.endCap = D2D1_CAP_STYLE_FLAT;
        style.dashCap = D2D1_CAP_STYLE_FLAT;
        style.lineJoin = D2D1_LINE_JOIN_MITER;
        renderer_->d2dFactory()->CreateStrokeStyle(style, nullptr, 0, &rect_stroke_);
        style.lineJoin = D2D1_LINE_JOIN_ROUND;
        renderer_->d2dFactory()->CreateStrokeStyle(style, nullptr, 0, &butt_stroke_);
        style.startCap = D2D1_CAP_STYLE_ROUND;
        style.endCap = D2D1_CAP_STYLE_ROUND;
        style.dashCap = D2D1_CAP_STYLE_ROUND;
        renderer_->d2dFactory()->CreateStrokeStyle(style, nullptr, 0, &round_stroke_);
    }

    ~GpuSurfaceImpl() override {
        releaseDeviceResources(false);
        releaseCom(round_stroke_);
        releaseCom(butt_stroke_);
        releaseCom(rect_stroke_);
    }

    int present(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info) override;
    bool paint(const RECT *paint_rects, size_t paint_rect_count) override;
    void abandonContent() override { releaseDeviceResources(true); }
    bool hasContent() const override { return content_valid_ && backing_bitmap_; }
    bool readColorAt(double logical_x, double logical_y, uint32_t *color) override;
    uint32_t representativeColorAt(double logical_x, double logical_y) const override;

private:
    struct CachedBitmap {
        uint64_t serial = 0;
        ID2D1Bitmap *bitmap = nullptr;
    };

    void releaseImageBitmaps() {
        for (auto &entry : image_bitmaps_) releaseCom(entry.second.bitmap);
        image_bitmaps_.clear();
    }

    void releaseImageBitmap(uint64_t id) {
        auto found = image_bitmaps_.find(id);
        if (found == image_bitmaps_.end()) return;
        releaseCom(found->second.bitmap);
        image_bitmaps_.erase(found);
    }

    void releaseDeviceResources(bool drop_retained) {
        releaseImageBitmaps();
        releaseCom(blur_snapshot_);
        releaseCom(backing_bitmap_);
        releaseCom(backing_target_);
        releaseCom(window_target_);
        content_valid_ = false;
        if (drop_retained) {
            retained_valid_ = false;
            retained_commands_.clear();
            retained_order_.clear();
        }
    }

    bool ensureWindowTarget() {
        if (window_target_) return true;
        RECT client = {};
        if (!hwnd_ || !GetClientRect(hwnd_, &client)) return false;
        const UINT width = static_cast<UINT>(std::max<LONG>(1, client.right - client.left));
        const UINT height = static_cast<UINT>(std::max<LONG>(1, client.bottom - client.top));
        const D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_HARDWARE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
            static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_),
            D2D1_RENDER_TARGET_USAGE_NONE,
            D2D1_FEATURE_LEVEL_DEFAULT);
        const D2D1_HWND_RENDER_TARGET_PROPERTIES hwnd_properties = D2D1::HwndRenderTargetProperties(
            hwnd_, D2D1::SizeU(width, height), D2D1_PRESENT_OPTIONS_NONE);
        return SUCCEEDED(renderer_->d2dFactory()->CreateHwndRenderTarget(properties, hwnd_properties, &window_target_));
    }

    bool ensureTargets(double surface_width, double surface_height, double scale, uint32_t pixel_width, uint32_t pixel_height) {
        const bool dimensions_changed = backing_target_ &&
            (pixel_width_ != pixel_width || pixel_height_ != pixel_height || scale_ != scale ||
             surface_width_ != surface_width || surface_height_ != surface_height);
        if (dimensions_changed) {
            releaseImageBitmaps();
            releaseCom(blur_snapshot_);
            releaseCom(backing_bitmap_);
            releaseCom(backing_target_);
            content_valid_ = false;
        }
        scale_ = scale;
        surface_width_ = surface_width;
        surface_height_ = surface_height;
        pixel_width_ = pixel_width;
        pixel_height_ = pixel_height;

        if (window_target_) window_target_->SetDpi(static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        if (!ensureWindowTarget()) return false;
        if (backing_target_) return true;

        const D2D1_SIZE_F desired = D2D1::SizeF(static_cast<FLOAT>(surface_width_), static_cast<FLOAT>(surface_height_));
        const D2D1_SIZE_U pixels = D2D1::SizeU(pixel_width_, pixel_height_);
        const D2D1_PIXEL_FORMAT format = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
        HRESULT result = window_target_->CreateCompatibleRenderTarget(
            &desired, &pixels, &format, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_GDI_COMPATIBLE, &backing_target_);
        if (SUCCEEDED(result) && backing_target_) {
            backing_target_->SetDpi(static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        }
        return SUCCEEDED(result) && backing_target_;
    }

    bool makeBrush(const Paint &paint, float opacity, ID2D1Brush **brush) {
        if (!brush || !backing_target_) return false;
        *brush = nullptr;
        if (paint.kind == Paint::Kind::color) {
            ID2D1SolidColorBrush *solid = nullptr;
            if (FAILED(backing_target_->CreateSolidColorBrush(d2dColor(paint.color, opacity), &solid))) return false;
            *brush = solid;
            return true;
        }
        if (paint.kind != Paint::Kind::linear_gradient || paint.stops.empty()) return false;
        std::vector<D2D1_GRADIENT_STOP> stops;
        stops.reserve(paint.stops.size());
        for (const GradientStop &source : paint.stops) {
            D2D1_GRADIENT_STOP stop = {};
            stop.position = clamp01(source.offset);
            stop.color = d2dColor(source.color, opacity);
            stops.push_back(stop);
        }
        ID2D1GradientStopCollection *collection = nullptr;
        ID2D1LinearGradientBrush *gradient = nullptr;
        HRESULT result = backing_target_->CreateGradientStopCollection(
            stops.data(), static_cast<UINT32>(stops.size()), D2D1_GAMMA_2_2,
            D2D1_EXTEND_MODE_CLAMP, &collection);
        if (SUCCEEDED(result)) {
            result = backing_target_->CreateLinearGradientBrush(
                D2D1::LinearGradientBrushProperties(
                    D2D1::Point2F(paint.start.x, paint.start.y),
                    D2D1::Point2F(paint.end.x, paint.end.y)), collection, &gradient);
        }
        releaseCom(collection);
        if (FAILED(result)) {
            releaseCom(gradient);
            return false;
        }
        *brush = gradient;
        return true;
    }

    bool makeShapeGeometry(const Shape &shape, bool filled, ID2D1Geometry **geometry) {
        if (!geometry) return false;
        *geometry = nullptr;
        if (shape.kind == Shape::Kind::rect) {
            ID2D1RectangleGeometry *rect = nullptr;
            if (FAILED(renderer_->d2dFactory()->CreateRectangleGeometry(d2dRect(shape.rect), &rect))) return false;
            *geometry = rect;
            return true;
        }
        if (shape.kind == Shape::Kind::rounded_rect || shape.kind == Shape::Kind::stroke_rect) {
            ID2D1PathGeometry *rounded = nullptr;
            if (!makeRoundedGeometry(renderer_->d2dFactory(), shape.rect, shape.radius, &rounded)) return false;
            *geometry = rounded;
            return true;
        }
        if (shape.kind == Shape::Kind::path) {
            ID2D1PathGeometry *path = nullptr;
            if (!makePathGeometry(renderer_->d2dFactory(), shape, filled, &path)) return false;
            *geometry = path;
            return true;
        }
        return false;
    }

    bool drawPaintedShape(const Command &command, bool stroke) {
        const float stroke_width = canvasStrokeWidth(
            command.shape.kind == Shape::Kind::line ? command.shape.width : command.stroke_width);
        /* Match the reference renderer: non-positive strokes are no-ops,
         * while positive fractional widths remain valid Direct2D widths. */
        if (stroke && stroke_width <= 0) return true;
        ID2D1Brush *brush = nullptr;
        if (!makeBrush(command.paint, clamp01(command.opacity), &brush)) return false;
        if (command.shape.kind == Shape::Kind::line) {
            if (!stroke) {
                releaseCom(brush);
                return false;
            }
            backing_target_->DrawLine(
                D2D1::Point2F(command.shape.from.x, command.shape.from.y),
                D2D1::Point2F(command.shape.to.x, command.shape.to.y),
                brush, stroke_width, command.cap == 1 ? round_stroke_ : butt_stroke_);
            releaseCom(brush);
            return true;
        }
        ID2D1Geometry *geometry = nullptr;
        if (!makeShapeGeometry(command.shape, !stroke, &geometry)) {
            releaseCom(brush);
            return false;
        }
        if (stroke) {
            ID2D1StrokeStyle *stroke_style = command.shape.kind == Shape::Kind::stroke_rect
                ? rect_stroke_
                : (command.cap == 1 ? round_stroke_ : butt_stroke_);
            backing_target_->DrawGeometry(geometry, brush, stroke_width, stroke_style);
        } else {
            backing_target_->FillGeometry(geometry, brush);
        }
        releaseCom(geometry);
        releaseCom(brush);
        return true;
    }

    bool ensureImageBitmap(uint64_t id, ID2D1Bitmap **bitmap) {
        if (!bitmap || !backing_target_) return false;
        *bitmap = nullptr;
        auto resource_found = image_cache_.find(id);
        if (resource_found == image_cache_.end() || !resource_found->second) return true;
        const std::shared_ptr<ImageResource> &resource = resource_found->second;
        CachedBitmap &cached = image_bitmaps_[id];
        if (cached.bitmap && cached.serial == resource->serial) {
            *bitmap = cached.bitmap;
            return true;
        }
        releaseCom(cached.bitmap);
        cached.serial = 0;
        const D2D1_BITMAP_PROPERTIES properties = D2D1::BitmapProperties(
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
        HRESULT result = backing_target_->CreateBitmap(
            D2D1::SizeU(resource->width, resource->height), resource->bgra.data(),
            resource->width * 4, properties, &cached.bitmap);
        if (FAILED(result) || !cached.bitmap) return false;
        cached.serial = resource->serial;
        *bitmap = cached.bitmap;
        return true;
    }

    bool drawImage(const Command &command) {
        ID2D1Bitmap *bitmap = nullptr;
        if (!ensureImageBitmap(command.image.id, &bitmap)) return false;
        if (!bitmap) return true; /* registered image not available yet */
        const auto resource_found = image_cache_.find(command.image.id);
        if (resource_found == image_cache_.end() || !resource_found->second) return true;
        const ImageResource &resource = *resource_found->second;

        Rect source = command.image.has_src ? normalized(command.image.src) :
            Rect{0, 0, static_cast<float>(resource.width), static_cast<float>(resource.height)};
        source = intersection(source, Rect{0, 0, static_cast<float>(resource.width), static_cast<float>(resource.height)});
        Rect requested = normalized(command.image.dst);
        if (empty(source) || empty(requested)) return false;
        Rect destination = requested;
        if (command.image.fit == 1 || command.image.fit == 2) {
            const float source_aspect = source.width / source.height;
            const float destination_aspect = requested.width / requested.height;
            float width = requested.width;
            float height = requested.height;
            if (command.image.fit == 1) {
                if (destination_aspect > source_aspect) width = height * source_aspect;
                else height = width / source_aspect;
            } else {
                if (destination_aspect > source_aspect) height = width / source_aspect;
                else width = height * source_aspect;
            }
            destination = {
                requested.x + (requested.width - width) * 0.5f,
                requested.y + (requested.height - height) * 0.5f,
                width,
                height,
            };
        }

        ID2D1Layer *layer = nullptr;
        ID2D1PathGeometry *mask = nullptr;
        const float max_radius = std::max(std::max(command.image.radius.top_left, command.image.radius.top_right),
            std::max(command.image.radius.bottom_right, command.image.radius.bottom_left));
        if (max_radius > 0) {
            if (!makeRoundedGeometry(renderer_->d2dFactory(), requested, command.image.radius, &mask) ||
                FAILED(backing_target_->CreateLayer(nullptr, &layer))) {
                releaseCom(mask);
                releaseCom(layer);
                return false;
            }
            D2D1_LAYER_PARAMETERS parameters = D2D1::LayerParameters();
            parameters.contentBounds = D2D1::InfiniteRect();
            parameters.geometricMask = mask;
            parameters.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
            parameters.opacity = 1.0f;
            backing_target_->PushLayer(parameters, layer);
        } else if (command.image.fit == 2) {
            /* Cover expands one destination axis past the requested frame.
             * A zero-radius image still has a rectangular destination mask;
             * without this clip the expanded bitmap paints over siblings. */
            backing_target_->PushAxisAlignedClip(d2dRect(requested), D2D1_ANTIALIAS_MODE_ALIASED);
        }
        backing_target_->DrawBitmap(bitmap, d2dRect(destination),
            clamp01(command.opacity * command.image.opacity),
            command.image.sampling == 0 ? D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR : D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
            d2dRect(source));
        if (layer) backing_target_->PopLayer();
        else if (command.image.fit == 2) backing_target_->PopAxisAlignedClip();
        releaseCom(layer);
        releaseCom(mask);
        return true;
    }

    static bool widenUtf8(const std::string &value, std::wstring *wide) {
        if (!wide) return false;
        wide->clear();
        if (value.empty()) return true;
        if (value.size() > INT_MAX) return false;
        const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
        if (count <= 0) return false;
        wide->resize(static_cast<size_t>(count));
        return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), wide->data(), count) == count;
    }

    static DWRITE_FONT_WEIGHT canvasFontWeight(uint64_t font_id) {
        if (font_id == 3) return DWRITE_FONT_WEIGHT_MEDIUM;
        if (font_id == 4 || font_id == 6) return DWRITE_FONT_WEIGHT_BOLD;
        return DWRITE_FONT_WEIGHT_NORMAL;
    }

    static DWRITE_FONT_STYLE canvasFontStyle(uint64_t font_id) {
        return font_id == 5 || font_id == 6 ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
    }

    std::shared_ptr<FontResource> fontResource(uint64_t font_id) const {
        std::shared_ptr<FontResource> resource = renderer_->font(canvasFontResourceId(font_id));
        if (!resource) {
            const uint64_t fallback_id = canvasFallbackFontResourceId(font_id);
            if (fallback_id != 0) resource = renderer_->font(fallback_id);
        }
        return resource;
    }

    bool createGlyphFace(uint64_t font_id, IDWriteFontFace **face) const {
        if (!face) return false;
        *face = nullptr;
        const DWRITE_FONT_WEIGHT weight = canvasFontWeight(font_id);
        const DWRITE_FONT_STYLE style = canvasFontStyle(font_id);
        std::shared_ptr<FontResource> custom = fontResource(font_id);
        IDWriteFont *font = nullptr;
        HRESULT result = E_FAIL;
        if (custom) {
            IDWriteFontFamily1 *family = nullptr;
            result = custom->collection->GetFontFamily(0, &family);
            if (SUCCEEDED(result)) result = family->GetFirstMatchingFont(
                weight, DWRITE_FONT_STRETCH_NORMAL, style, &font);
            releaseCom(family);
        } else {
            IDWriteFontCollection *collection = nullptr;
            IDWriteFontFamily *family = nullptr;
            const wchar_t *family_name = font_id == 2 ? L"Consolas" : L"Segoe UI";
            UINT32 family_index = 0;
            BOOL exists = FALSE;
            result = renderer_->dwriteFactory()->GetSystemFontCollection(&collection);
            if (SUCCEEDED(result)) result = collection->FindFamilyName(family_name, &family_index, &exists);
            if (SUCCEEDED(result) && !exists) result = E_FAIL;
            if (SUCCEEDED(result)) result = collection->GetFontFamily(family_index, &family);
            if (SUCCEEDED(result)) result = family->GetFirstMatchingFont(
                weight, DWRITE_FONT_STRETCH_NORMAL, style, &font);
            releaseCom(family);
            releaseCom(collection);
        }
        if (SUCCEEDED(result) && font) result = font->CreateFontFace(face);
        releaseCom(font);
        return SUCCEEDED(result) && *face;
    }

    bool createTextFormat(const TextCommand &text, IDWriteTextFormat **format) {
        if (!format) return false;
        *format = nullptr;
        /* IDs 3..6 are styled variants of the built-in sans face, not
         * independent assets. Resolve them through registered Geist id 1
         * and let DirectWrite select/simulate the requested traits. */
        const uint64_t resource_id = canvasFontResourceId(text.font_id);
        std::shared_ptr<FontResource> custom = renderer_->font(resource_id);
        /* An absent application font follows the reference/AppKit fallback
         * contract too: mono keeps its platform mono fallback, every other
         * id uses bundled Geist when that registration succeeded. */
        if (!custom) {
            const uint64_t fallback_id = canvasFallbackFontResourceId(text.font_id);
            if (fallback_id != 0) custom = renderer_->font(fallback_id);
        }
        const wchar_t *family = L"Segoe UI";
        IDWriteFontCollection *collection = nullptr;
        const DWRITE_FONT_WEIGHT weight = canvasFontWeight(text.font_id);
        const DWRITE_FONT_STYLE style = canvasFontStyle(text.font_id);
        if (custom) {
            family = custom->family.c_str();
            collection = custom->collection;
        } else if (text.font_id == 2) family = L"Consolas";
        HRESULT result = renderer_->dwriteFactory()->CreateTextFormat(
            family, collection, weight, style, DWRITE_FONT_STRETCH_NORMAL,
            std::max(1.0f, text.size), L"en-us", format);
        if (FAILED(result) || !*format) return false;
        (*format)->SetTextAlignment(text.align == 1 ? DWRITE_TEXT_ALIGNMENT_CENTER :
            (text.align == 2 ? DWRITE_TEXT_ALIGNMENT_TRAILING : DWRITE_TEXT_ALIGNMENT_LEADING));
        (*format)->SetWordWrapping(text.wrap == 0 ? DWRITE_WORD_WRAPPING_NO_WRAP :
            (text.wrap == 2 ? DWRITE_WORD_WRAPPING_CHARACTER : DWRITE_WORD_WRAPPING_WRAP));
        if (text.line_height > 0) {
            (*format)->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, text.line_height, std::min(text.line_height, text.size));
        }
        return true;
    }

    bool createTextLayout(
        const std::wstring &value,
        IDWriteTextFormat *format,
        float width,
        float height,
        IDWriteTextLayout **layout
    ) {
        if (!format || !layout || !renderer_->fontFallback()) return false;
        *layout = nullptr;
        HRESULT result = renderer_->dwriteFactory()->CreateTextLayout(
            value.data(), static_cast<UINT32>(value.size()), format,
            std::max(1.0f, width), std::max(1.0f, height), layout);
        IDWriteTextLayout2 *layout2 = nullptr;
        if (SUCCEEDED(result) && *layout) {
            result = (*layout)->QueryInterface(
                __uuidof(IDWriteTextLayout2), reinterpret_cast<void **>(&layout2));
        }
        if (SUCCEEDED(result) && layout2) {
            result = layout2->SetFontFallback(renderer_->fontFallback());
        }
        releaseCom(layout2);
        if (FAILED(result)) {
            releaseCom(*layout);
            return false;
        }
        return *layout != nullptr;
    }

    bool drawText(const Command &command) {
        const TextCommand &text = command.text;
        IDWriteTextFormat *format = nullptr;
        ID2D1SolidColorBrush *brush = nullptr;
        if (!createTextFormat(text, &format) ||
            FAILED(backing_target_->CreateSolidColorBrush(d2dColor(text.color, command.opacity), &brush))) {
            releaseCom(brush);
            releaseCom(format);
            return false;
        }

        auto draw_line = [&](const std::string &utf8, float x, float baseline) -> bool {
            if (utf8.empty()) return true;
            std::wstring value;
            if (!widenUtf8(utf8, &value)) return false;
            IDWriteTextLayout *layout = nullptr;
            HRESULT result = createTextLayout(
                value, format, 100000.0f, std::max(4.0f, text.size * 4.0f), &layout) ? S_OK : E_FAIL;
            DWRITE_LINE_METRICS metrics = {};
            UINT32 actual = 0;
            if (SUCCEEDED(result)) result = layout->GetLineMetrics(&metrics, 1, &actual);
            if (SUCCEEDED(result) && actual == 1) {
                backing_target_->DrawTextLayout(D2D1::Point2F(x, baseline - metrics.baseline), layout, brush,
                    D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            }
            releaseCom(layout);
            return SUCCEEDED(result) && actual == 1;
        };

        if (text.has_positioned_glyphs) {
            bool result = true;
            std::map<uint64_t, IDWriteFontFace *> faces;
            for (const PositionedGlyph &glyph : text.positioned_glyphs) {
                IDWriteFontFace *face = nullptr;
                auto found = faces.find(glyph.font_id);
                if (found == faces.end()) {
                    if (!createGlyphFace(glyph.font_id, &face)) {
                        result = false;
                        break;
                    }
                    faces[glyph.font_id] = face;
                } else {
                    face = found->second;
                }
                const UINT16 glyph_index = glyph.id;
                const FLOAT glyph_advance = glyph.advance;
                const DWRITE_GLYPH_OFFSET glyph_offset = {};
                DWRITE_GLYPH_RUN glyph_run = {};
                glyph_run.fontFace = face;
                glyph_run.fontEmSize = std::max(1.0f, text.size);
                glyph_run.glyphCount = 1;
                glyph_run.glyphIndices = &glyph_index;
                glyph_run.glyphAdvances = &glyph_advance;
                glyph_run.glyphOffsets = &glyph_offset;
                backing_target_->DrawGlyphRun(
                    D2D1::Point2F(glyph.x, glyph.baseline), &glyph_run, brush, DWRITE_MEASURING_MODE_NATURAL);
            }
            if (result) {
                /* Positioned fragments already carry their final x; do not
                 * apply center/trailing alignment inside the wide one-line
                 * helper layout a second time. */
                format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
                for (const PositionedTextFragment &fragment : text.positioned_fragments) {
                    if (!draw_line(fragment.text, fragment.x, fragment.baseline)) {
                        result = false;
                        break;
                    }
                }
            }
            for (auto &entry : faces) releaseCom(entry.second);
            releaseCom(brush);
            releaseCom(format);
            return result;
        }

        bool result = true;
        if (text.has_layout && text.has_lines) {
            /* Engine-measured lines already carry their final aligned x.
             * Applying DirectWrite alignment again would center/trail the
             * run inside the deliberately wide one-line layout and move
             * short labels (counts, centered buttons) off the surface. */
            format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
            for (const TextLine &line : text.lines) {
                if (!draw_line(line.text, line.x, line.baseline)) {
                    result = false;
                    break;
                }
            }
        } else if (!text.has_layout) {
            /* A raw DrawText origin is a baseline, not the top of an em
             * box. DirectWrite's baseline comes from the registered face's
             * metrics and is not guaranteed to equal `size`, so use the
             * same measured-baseline path as engine-planned lines. */
            result = draw_line(text.text, text.origin.x, text.origin.y);
        } else {
            std::wstring value;
            result = widenUtf8(text.text, &value);
            if (result && !value.empty()) {
                const float width = text.max_width > 0 ? text.max_width : 100000.0f;
                const float height = std::max(text.line_height, text.size * 1.25f) * 4096.0f;
                IDWriteTextLayout *layout = nullptr;
                result = createTextLayout(value, format, width, height, &layout);
                if (result) {
                    backing_target_->DrawTextLayout(
                        D2D1::Point2F(text.origin.x, text.origin.y - text.size), layout, brush,
                        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
                }
                releaseCom(layout);
            }
        }
        releaseCom(brush);
        releaseCom(format);
        return result;
    }

    bool drawShadow(const Command &command) {
        const Effect &effect = command.effect;
        const float blur = std::max(0.0f, effect.blur);
        const unsigned steps = blur > 0.25f ? 12u : 1u;
        float weight_sum = 0;
        for (unsigned index = 0; index < steps; ++index) weight_sum += static_cast<float>(index + 1);
        for (unsigned index = 0; index < steps; ++index) {
            const float inward = static_cast<float>(index + 1) / static_cast<float>(steps);
            /* Spread is signed: negative values inset the shadow caster
             * before the blur halo expands it. The default card/overlay
             * tokens depend on that contraction. */
            const float expansion = effect.spread + blur * (1.0f - inward);
            Rect rect = normalized(effect.rect);
            rect.x += effect.offset.x - expansion;
            rect.y += effect.offset.y - expansion;
            rect.width += expansion * 2;
            rect.height += expansion * 2;
            if (rect.width <= 0 || rect.height <= 0) continue;
            Radius radius = effect.radius;
            radius.top_left = std::max(0.0f, radius.top_left + expansion);
            radius.top_right = std::max(0.0f, radius.top_right + expansion);
            radius.bottom_right = std::max(0.0f, radius.bottom_right + expansion);
            radius.bottom_left = std::max(0.0f, radius.bottom_left + expansion);
            ID2D1PathGeometry *geometry = nullptr;
            ID2D1SolidColorBrush *brush = nullptr;
            Color layer_color = effect.color;
            layer_color.a *= static_cast<float>(index + 1) / weight_sum;
            if (!makeRoundedGeometry(renderer_->d2dFactory(), rect, radius, &geometry) ||
                FAILED(backing_target_->CreateSolidColorBrush(d2dColor(layer_color, command.opacity), &brush))) {
                releaseCom(brush);
                releaseCom(geometry);
                return false;
            }
            backing_target_->FillGeometry(geometry, brush);
            releaseCom(brush);
            releaseCom(geometry);
        }
        return true;
    }

    bool ensureBlurSnapshot() {
        if (blur_snapshot_) return true;
        if (!backing_target_ || pixel_width_ == 0 || pixel_height_ == 0) return false;
        const D2D1_BITMAP_PROPERTIES properties = D2D1::BitmapProperties(
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        return SUCCEEDED(backing_target_->CreateBitmap(
            D2D1::SizeU(pixel_width_, pixel_height_), nullptr, 0, properties, &blur_snapshot_)) && blur_snapshot_;
    }

    /* Resume the backing target after a segment-ending backdrop blur.
     * Direct2D 1.0 has no effects graph, but its bitmaps and compatible
     * targets stay in the hardware resource domain: copy the current
     * backdrop on-GPU, approximate the box blur with a 5x5 separable-
     * Gaussian sample kernel into a temporary GPU target, then composite
     * that target over only the affected rect. There is no readback and
     * no full RGBA allocation/swizzle on the CPU. */
    Rect blurTarget(const Command &command, const Rect *outer_clip) const {
        Rect target = command.has_transform ? transformedRect(command.effect.rect, command.transform) : normalized(command.effect.rect);
        target = intersection(target, Rect{0, 0, static_cast<float>(surface_width_), static_cast<float>(surface_height_)});
        if (command.has_clip) target = intersection(target, command.clip);
        if (outer_clip) target = intersection(target, *outer_clip);
        return target;
    }

    bool resumeAndDrawBlur(const Command &command, Rect target) {
        auto resume = [&] {
            backing_target_->BeginDraw();
            backing_target_->SetTransform(D2D1::Matrix3x2F::Identity());
        };

        releaseCom(backing_bitmap_);
        if (FAILED(backing_target_->GetBitmap(&backing_bitmap_)) || !backing_bitmap_ ||
            !ensureBlurSnapshot() || FAILED(blur_snapshot_->CopyFromBitmap(nullptr, backing_bitmap_, nullptr))) {
            resume();
            return false;
        }

        const float opacity = clamp01(command.opacity);

        const double pixel_width_value = std::ceil(target.width * scale_);
        const double pixel_height_value = std::ceil(target.height * scale_);
        if (pixel_width_value < 1 || pixel_height_value < 1 ||
            pixel_width_value > kMaxSurfacePixels || pixel_height_value > kMaxSurfacePixels) {
            resume();
            return false;
        }
        const D2D1_SIZE_F desired = D2D1::SizeF(target.width, target.height);
        const D2D1_SIZE_U pixels = D2D1::SizeU(
            static_cast<UINT32>(pixel_width_value), static_cast<UINT32>(pixel_height_value));
        const D2D1_PIXEL_FORMAT format = D2D1::PixelFormat(
            DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
        ID2D1BitmapRenderTarget *temporary = nullptr;
        ID2D1Bitmap *blurred = nullptr;
        HRESULT result = backing_target_->CreateCompatibleRenderTarget(
            &desired, &pixels, &format, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE, &temporary);
        if (FAILED(result) || !temporary) {
            releaseCom(temporary);
            resume();
            return false;
        }
        temporary->SetDpi(static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
        temporary->BeginDraw();
        temporary->Clear(D2D1::ColorF(0, 0, 0, 0));
        /* D2D's target DPI applies the presentation scale, but this blur
         * bypasses the command transform after converting its rect to a
         * device-space bounding box. Scale the kernel explicitly so a
         * transformed blur keeps parity with the reference/AppKit paths. */
        const float radius = std::min(64.0f,
            std::max(0.0f, command.effect.blur * transformScale(command.transform)));
        const float offsets[5] = {-1.0f, -0.5f, 0.0f, 0.5f, 1.0f};
        const float weights[5] = {1.0f, 4.0f, 6.0f, 4.0f, 1.0f};
        ID2D1BitmapBrush *sample_brush = nullptr;
        const D2D1_BITMAP_BRUSH_PROPERTIES sample_properties = D2D1::BitmapBrushProperties(
            D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        result = temporary->CreateBitmapBrush(blur_snapshot_, &sample_properties, nullptr, &sample_brush);
        if (SUCCEEDED(result) && !sample_brush) result = E_FAIL;
        if (SUCCEEDED(result) && sample_brush) {
            float accumulated_weight = 0;
            for (size_t y = 0; y < 5; ++y) {
                for (size_t x = 0; x < 5; ++x) {
                    const float dx = offsets[x] * radius;
                    const float dy = offsets[y] * radius;
                    const float weight = weights[x] * weights[y];
                    accumulated_weight += weight;
                    /* Translate the whole-surface snapshot beneath the
                     * target-local output. The brush clamps each sample
                     * at a surface edge, so a full-surface blur keeps
                     * nonzero kernel offsets instead of collapsing every
                     * tap onto the unblurred source. */
                    sample_brush->SetOpacity(weight / accumulated_weight);
                    sample_brush->SetTransform(D2D1::Matrix3x2F::Translation(
                        -(target.x + dx), -(target.y + dy)));
                    temporary->FillRectangle(
                        D2D1::RectF(0, 0, target.width, target.height), sample_brush);
                }
            }
        }
        const HRESULT draw_result = temporary->EndDraw();
        if (SUCCEEDED(result)) result = draw_result;
        if (SUCCEEDED(result)) result = temporary->GetBitmap(&blurred);

        resume();
        if (SUCCEEDED(result) && blurred) {
            backing_target_->PushAxisAlignedClip(d2dRect(target), D2D1_ANTIALIAS_MODE_ALIASED);
            backing_target_->DrawBitmap(blurred, d2dRect(target), opacity,
                D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
            backing_target_->PopAxisAlignedClip();
        }
        releaseCom(sample_brush);
        releaseCom(blurred);
        releaseCom(temporary);
        return SUCCEEDED(result);
    }

    bool drawCommandList(const std::vector<const Command *> &commands, const Rect *outer_clip) {
        for (const Command *command : commands) {
            if (command->kind == 13) {
                /* Cull before ending the current segment or copying the
                 * full backing bitmap. A localized blur outside a dirty
                 * patch must cost no more than any other culled command. */
                const Rect target = blurTarget(*command, outer_clip);
                if (empty(target) || command->effect.blur <= 0 || command->opacity <= 0) continue;
                const HRESULT segment = backing_target_->EndDraw();
                if (FAILED(segment)) {
                    backing_target_->BeginDraw();
                    return false;
                }
                if (!resumeAndDrawBlur(*command, target)) return false;
                continue;
            }
            if (!drawCommand(*command, outer_clip)) return false;
        }
        return true;
    }

    bool drawCommand(const Command &command, const Rect *outer_clip) {
        if (outer_clip && !intersects(command.bounds, *outer_clip)) return true;
        backing_target_->SetTransform(D2D1::Matrix3x2F::Identity());
        if (outer_clip) backing_target_->PushAxisAlignedClip(d2dRect(*outer_clip), D2D1_ANTIALIAS_MODE_ALIASED);
        if (command.has_clip) backing_target_->PushAxisAlignedClip(d2dRect(command.clip), D2D1_ANTIALIAS_MODE_ALIASED);
        if (command.has_transform) {
            const Affine &value = command.transform;
            backing_target_->SetTransform(D2D1::Matrix3x2F(value.a, value.b, value.c, value.d, value.tx, value.ty));
        }
        bool ok = false;
        switch (command.kind) {
            case 0: case 1: case 2: case 3: case 8:
                ok = drawPaintedShape(command, false);
                break;
            case 4: case 5: case 6: case 7: case 9:
                ok = drawPaintedShape(command, true);
                break;
            case 10:
                ok = drawImage(command);
                break;
            case 11:
                ok = drawText(command);
                break;
            case 12:
                ok = drawShadow(command);
                break;
            default:
                ok = false;
                break;
        }
        backing_target_->SetTransform(D2D1::Matrix3x2F::Identity());
        if (command.has_clip) backing_target_->PopAxisAlignedClip();
        if (outer_clip) backing_target_->PopAxisAlignedClip();
        return ok;
    }

    bool commandsSupported(const std::vector<const Command *> &commands) const {
        for (const Command *command : commands) {
            if (!command || command->kind > 13) return false;
            if (command->kind <= 9 && (command->shape.kind == Shape::Kind::none || command->paint.kind == Paint::Kind::none)) return false;
            if (command->kind == 10 && command->image.id == 0) return false;
            if (command->kind == 12 && command->effect.kind != Effect::Kind::shadow) return false;
            if (command->kind == 13 && command->effect.kind != Effect::Kind::blur) return false;
        }
        return true;
    }

    bool applyImageActions(const DecodedPacket &packet) {
        auto next = image_cache_;
        for (const ImageAction &action : packet.image_actions) {
            if (action.kind == 2) next.erase(action.id);
            else if (!imageActionResolvesResource(action.kind)) return false;
        }
        for (const ImageAction &action : packet.image_actions) {
            if (!imageActionResolvesResource(action.kind)) continue;
            if (action.image_index == UINT32_MAX || action.image_index >= packet.images.size()) return false;
            const ImageMeta &meta = packet.images[action.image_index];
            if (meta.id != action.id || meta.id == 0) return false;
            std::shared_ptr<ImageResource> resource = renderer_->image(meta.id);
            if (!imageMetadataMatchesResource(
                    resource != nullptr,
                    meta.width,
                    meta.height,
                    resource ? resource->width : 0,
                    resource ? resource->height : 0)) return false;
            if (resource) next[meta.id] = std::move(resource);
            else next.erase(meta.id);
        }
        image_cache_ = std::move(next);
        /* The renderer-wide remove releases the shared pixels, but each
         * surface owns its own Direct2D bitmap. Any action that reconciles
         * an id to absent must drop that COM resource too so unregisters do
         * not leave stale texture memory behind. */
        for (const ImageAction &action : packet.image_actions) {
            if (image_cache_.find(action.id) == image_cache_.end()) {
                releaseImageBitmap(action.id);
            }
        }
        return true;
    }

    bool renderCommands(const std::vector<const Command *> &commands, const DecodedPacket &packet, Color clear, bool full_surface) {
        backing_target_->BeginDraw();
        backing_target_->SetTransform(D2D1::Matrix3x2F::Identity());
        bool ok = true;
        if (full_surface) {
            backing_target_->Clear(d2dColor(clear));
            ok = drawCommandList(commands, nullptr);
        } else if (packet.has_scissor) {
            std::vector<Rect> regions = packet.dirty_rects;
            if (regions.empty()) regions.push_back(packet.scissor);
            ID2D1SolidColorBrush *clear_brush = nullptr;
            if (FAILED(backing_target_->CreateSolidColorBrush(d2dColor(clear), &clear_brush))) ok = false;
            for (const Rect &source_region : regions) {
                if (!ok) break;
                Rect region = intersection(normalized(source_region), normalized(packet.scissor));
                region = intersection(region, Rect{0, 0, static_cast<float>(surface_width_), static_cast<float>(surface_height_)});
                if (empty(region)) continue;
                backing_target_->SetTransform(D2D1::Matrix3x2F::Identity());
                backing_target_->PushAxisAlignedClip(d2dRect(region), D2D1_ANTIALIAS_MODE_ALIASED);
                /* Normal gpu_surface windows are opaque; source-over is
                 * therefore byte-equivalent to copy-clear here. Alpha
                 * top-level windows intentionally use the pixel path. */
                backing_target_->FillRectangle(d2dRect(region), clear_brush);
                backing_target_->SetTransform(D2D1::Matrix3x2F::Identity());
                backing_target_->PopAxisAlignedClip();
                if (!drawCommandList(commands, &region)) { ok = false; break; }
            }
            releaseCom(clear_brush);
        } else {
            /* A load without a scissor intentionally overlays the
             * supplied command list without clearing retained pixels. */
            ok = drawCommandList(commands, nullptr);
        }
        const HRESULT end = backing_target_->EndDraw();
        if (!ok) return false;
        if (FAILED(end)) {
            releaseDeviceResources(true);
            return false;
        }
        releaseCom(backing_bitmap_);
        if (FAILED(backing_target_->GetBitmap(&backing_bitmap_)) || !backing_bitmap_) {
            releaseDeviceResources(true);
            return false;
        }
        content_valid_ = true;
        return true;
    }

    std::shared_ptr<GpuRendererImpl> renderer_;
    HWND hwnd_ = nullptr;
    ID2D1HwndRenderTarget *window_target_ = nullptr;
    ID2D1BitmapRenderTarget *backing_target_ = nullptr;
    ID2D1Bitmap *backing_bitmap_ = nullptr;
    ID2D1Bitmap *blur_snapshot_ = nullptr;
    ID2D1StrokeStyle *rect_stroke_ = nullptr;
    ID2D1StrokeStyle *butt_stroke_ = nullptr;
    ID2D1StrokeStyle *round_stroke_ = nullptr;
    std::map<uint64_t, CachedBitmap> image_bitmaps_;
    std::map<uint64_t, std::shared_ptr<ImageResource>> image_cache_;
    std::map<uint64_t, Command> retained_commands_;
    std::vector<uint64_t> retained_order_;
    uint64_t retained_generation_ = 0;
    bool retained_valid_ = false;
    std::vector<Command> last_commands_;
    Color clear_color_ = {};
    double surface_width_ = 0;
    double surface_height_ = 0;
    double scale_ = 1;
    uint32_t pixel_width_ = 0;
    uint32_t pixel_height_ = 0;
    bool content_valid_ = false;
};

int GpuSurfaceImpl::present(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info) {
    if (info) *info = {};
    /* A no-change packet is normally a cheap completion. After device
     * loss there is no retained bitmap to paint, though: decode the same
     * full-list payload and rebuild it. If the runtime first offers a
     * patch, retained_valid_ rejects it and the runtime resends a keyed
     * full packet in this frame. */
    if (!present.requires_render && content_valid_) return 1;
    if (!present.representable || present.unsupported_command_count != 0 ||
        !present.packet || present.packet_len == 0 || present.surface_width <= 0 || present.surface_height <= 0) return 0;

    const uint64_t decode_begin_ns = gpuClockNs();
    DecodedPacket packet;
    if (!decodePacket(present.packet, present.packet_len, &packet)) return 0;
    const uint64_t draw_begin_ns = gpuClockNs();
    const double scale = present.scale > 0 ? present.scale : 1.0;
    const double pixel_width_value = std::ceil(present.surface_width * scale);
    const double pixel_height_value = std::ceil(present.surface_height * scale);
    if (!std::isfinite(pixel_width_value) || !std::isfinite(pixel_height_value) ||
        pixel_width_value < 1 || pixel_height_value < 1 ||
        pixel_width_value > kMaxSurfacePixels || pixel_height_value > kMaxSurfacePixels) return 0;
    const uint32_t pixel_width = static_cast<uint32_t>(pixel_width_value);
    const uint32_t pixel_height = static_cast<uint32_t>(pixel_height_value);

    std::map<uint64_t, Command> next_retained;
    std::vector<uint64_t> next_order;
    std::vector<const Command *> draw_commands;
    const bool patch = packet.load_action == 3;
    if (patch) {
        if (!retained_valid_ || packet.generation == 0 || packet.generation != retained_generation_) return 0;
        next_retained = retained_commands_;
        for (uint64_t key : packet.evicts) {
            auto found = next_retained.find(key);
            if (found == next_retained.end()) {
                retained_valid_ = false;
                return 0;
            }
            next_retained.erase(found);
        }
        for (const KeyedCommand &upsert : packet.upserts) next_retained[upsert.key] = upsert.command;
        if (next_retained.size() > kRetainedCommandCap || packet.order.size() != next_retained.size()) {
            retained_valid_ = false;
            return 0;
        }
        std::set<uint64_t> seen;
        next_order.reserve(packet.order.size());
        draw_commands.reserve(packet.order.size());
        for (uint64_t key : packet.order) {
            auto found = next_retained.find(key);
            if (found == next_retained.end() || !seen.insert(key).second) {
                retained_valid_ = false;
                return 0;
            }
            next_order.push_back(key);
            draw_commands.push_back(&found->second);
        }
    } else {
        draw_commands.reserve(packet.commands.size());
        for (const KeyedCommand &keyed : packet.commands) draw_commands.push_back(&keyed.command);
    }
    if (present.command_count != 0 && present.command_count != draw_commands.size()) {
        if (patch) retained_valid_ = false;
        return 0;
    }
    if (!commandsSupported(draw_commands)) return 0;

    const bool full_surface = packet.load_action == 2 || (patch && !packet.has_scissor);
    const bool same_backing = content_valid_ && pixel_width_ == pixel_width && pixel_height_ == pixel_height &&
        surface_width_ == present.surface_width && surface_height_ == present.surface_height && scale_ == scale;
    if (!full_surface && !same_backing) {
        if (patch) retained_valid_ = false;
        return 0;
    }
    if (!ensureTargets(present.surface_width, present.surface_height, scale, pixel_width, pixel_height)) {
        releaseDeviceResources(true);
        return 0;
    }
    if (!full_surface && !content_valid_) {
        if (patch) retained_valid_ = false;
        return 0;
    }
    if (!applyImageActions(packet)) {
        if (patch) retained_valid_ = false;
        return 0;
    }

    const Color clear = {
        static_cast<float>(present.clear_rgba[0]) / 255.0f,
        static_cast<float>(present.clear_rgba[1]) / 255.0f,
        static_cast<float>(present.clear_rgba[2]) / 255.0f,
        /* Direct2D child surfaces are the opaque path. Per-pixel-alpha
         * top-level windows are refused before this renderer and use the
         * exact layered pixel compositor, matching the GDI path's forced
         * opaque destination alpha here. */
        1.0f,
    };
    if (!renderCommands(draw_commands, packet, clear, full_surface)) {
        if (patch) retained_valid_ = false;
        return 0;
    }

    if (patch) {
        retained_commands_ = std::move(next_retained);
        retained_order_ = std::move(next_order);
        /* generation is unchanged */
    } else {
        bool retainable = packet.load_action == 2 && packet.generation != 0 &&
            packet.commands.size() <= kRetainedCommandCap;
        std::map<uint64_t, Command> retained;
        std::vector<uint64_t> order;
        if (retainable) {
            for (const KeyedCommand &keyed : packet.commands) {
                if (retained.find(keyed.key) != retained.end()) {
                    retainable = false;
                    break;
                }
                retained.emplace(keyed.key, keyed.command);
                order.push_back(keyed.key);
            }
        }
        if (retainable) {
            retained_commands_ = std::move(retained);
            retained_order_ = std::move(order);
            retained_generation_ = packet.generation;
            retained_valid_ = true;
        } else {
            retained_commands_.clear();
            retained_order_.clear();
            retained_generation_ = 0;
            retained_valid_ = false;
        }
    }

    last_commands_.clear();
    last_commands_.reserve(draw_commands.size());
    if (patch) {
        for (uint64_t key : retained_order_) last_commands_.push_back(retained_commands_.at(key));
    } else {
        for (const KeyedCommand &keyed : packet.commands) last_commands_.push_back(keyed.command);
    }
    clear_color_ = clear;

    if (info) {
        info->did_render = true;
        info->decode_ns = draw_begin_ns - decode_begin_ns;
        info->draw_ns = gpuClockNs() - draw_begin_ns;
        info->nonblank = clear.r != 0 || clear.g != 0 || clear.b != 0 || !last_commands_.empty();
        info->sample_color = representativeColorAt(present.surface_width * 0.5, present.surface_height * 0.5);
        if (!full_surface && packet.has_scissor) {
            const Rect surface = {0, 0, static_cast<float>(present.surface_width), static_cast<float>(present.surface_height)};
            const Rect scissor = intersection(normalized(packet.scissor), surface);
            const std::vector<Rect> &regions = packet.dirty_rects;
            auto append_dirty = [&](Rect dirty) {
                dirty = intersection(normalized(dirty), scissor);
                if (empty(dirty) || info->dirty_rect_count >= kWindowsGpuDirtyRectCap) return;
                RECT &pixels = info->dirty_rects[info->dirty_rect_count];
                pixels.left = std::max<LONG>(0, static_cast<LONG>(std::floor(dirty.x * scale)));
                pixels.top = std::max<LONG>(0, static_cast<LONG>(std::floor(dirty.y * scale)));
                pixels.right = std::min<LONG>(static_cast<LONG>(pixel_width), static_cast<LONG>(std::ceil((dirty.x + dirty.width) * scale)));
                pixels.bottom = std::min<LONG>(static_cast<LONG>(pixel_height), static_cast<LONG>(std::ceil((dirty.y + dirty.height) * scale)));
                if (pixels.right > pixels.left && pixels.bottom > pixels.top) info->dirty_rect_count += 1;
            };
            if (regions.empty()) append_dirty(scissor);
            else for (Rect dirty : regions) append_dirty(dirty);
        }
    }
    return 1;
}

bool GpuSurfaceImpl::paint(const RECT *paint_rects, size_t paint_rect_count) {
    if (!content_valid_ || !backing_bitmap_) return true;
    if (paint_rect_count > 0 && paint_rects == nullptr) return false;
    if (!ensureWindowTarget()) return false;
    RECT client = {};
    if (!GetClientRect(hwnd_, &client)) return false;
    const UINT client_width = static_cast<UINT>(std::max<LONG>(1, client.right - client.left));
    const UINT client_height = static_cast<UINT>(std::max<LONG>(1, client.bottom - client.top));
    const D2D1_SIZE_U current = window_target_->GetPixelSize();
    if ((current.width != client_width || current.height != client_height) &&
        FAILED(window_target_->Resize(D2D1::SizeU(client_width, client_height)))) {
        releaseDeviceResources(true);
        return false;
    }
    window_target_->SetDpi(static_cast<FLOAT>(96.0 * scale_), static_cast<FLOAT>(96.0 * scale_));
    const float logical_client_width = static_cast<float>(client_width / scale_);
    const float logical_client_height = static_cast<float>(client_height / scale_);
    window_target_->BeginDraw();
    window_target_->SetTransform(D2D1::Matrix3x2F::Identity());
    for (size_t index = 0; index < paint_rect_count; ++index) {
        const RECT &paint_rect = paint_rects[index];
        const Rect clip = {
            static_cast<float>(paint_rect.left / scale_),
            static_cast<float>(paint_rect.top / scale_),
            static_cast<float>((paint_rect.right - paint_rect.left) / scale_),
            static_cast<float>((paint_rect.bottom - paint_rect.top) / scale_),
        };
        if (empty(clip)) continue;
        window_target_->PushAxisAlignedClip(d2dRect(clip), D2D1_ANTIALIAS_MODE_ALIASED);
        window_target_->DrawBitmap(backing_bitmap_,
            D2D1::RectF(0, 0, logical_client_width, logical_client_height), 1.0f,
            D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
        window_target_->PopAxisAlignedClip();
    }
    const HRESULT result = window_target_->EndDraw();
    if (result == D2DERR_RECREATE_TARGET || FAILED(result)) {
        releaseDeviceResources(true);
        return false;
    }
    return true;
}

bool GpuSurfaceImpl::readColorAt(double logical_x, double logical_y, uint32_t *color) {
    if (!color || !content_valid_ || !backing_target_ || !backing_bitmap_ || !(scale_ > 0) ||
        !std::isfinite(logical_x) || !std::isfinite(logical_y)) return false;
    const double pixel_x_value = std::floor(logical_x * scale_);
    const double pixel_y_value = std::floor(logical_y * scale_);
    if (pixel_x_value < 0 || pixel_y_value < 0 ||
        pixel_x_value >= pixel_width_ || pixel_y_value >= pixel_height_) return false;

    ID2D1GdiInteropRenderTarget *interop = nullptr;
    HRESULT result = backing_target_->QueryInterface(
        __uuidof(ID2D1GdiInteropRenderTarget), reinterpret_cast<void **>(&interop));
    if (FAILED(result) || !interop) {
        releaseCom(interop);
        return false;
    }

    /* The backing target alone is GDI-compatible. COPY synchronizes its
     * retained GPU bitmap into the returned DC, and GetPixel reads exactly
     * one device pixel. Hidden-titlebar caption sampling is the sole caller,
     * so ordinary packet frames never pay this synchronization cost. */
    backing_target_->BeginDraw();
    HDC dc = nullptr;
    result = interop->GetDC(D2D1_DC_INITIALIZE_MODE_COPY, &dc);
    COLORREF sampled = CLR_INVALID;
    HRESULT released = S_OK;
    if (SUCCEEDED(result) && dc) {
        sampled = GetPixel(dc, static_cast<int>(pixel_x_value), static_cast<int>(pixel_y_value));
        released = interop->ReleaseDC(nullptr);
    }
    const HRESULT ended = backing_target_->EndDraw();
    releaseCom(interop);
    if (FAILED(result) || FAILED(released) || FAILED(ended) || sampled == CLR_INVALID) return false;
    *color = 0xff000000u |
        (static_cast<uint32_t>(GetRValue(sampled)) << 16) |
        (static_cast<uint32_t>(GetGValue(sampled)) << 8) |
        static_cast<uint32_t>(GetBValue(sampled));
    return true;
}

uint32_t GpuSurfaceImpl::representativeColorAt(double logical_x, double logical_y) const {
    Color result = clear_color_;
    for (const Command &command : last_commands_) {
        if (!contains(command.bounds, logical_x, logical_y) || command.opacity <= 0) continue;
        const bool solid_fill = (command.kind == 0 || command.kind == 2 || command.kind == 8) &&
            command.paint.kind == Paint::Kind::color;
        if (!solid_fill) continue;
        const Color source = command.paint.color;
        const float alpha = clamp01(source.a * command.opacity);
        result.r = source.r * alpha + result.r * (1.0f - alpha);
        result.g = source.g * alpha + result.g * (1.0f - alpha);
        result.b = source.b * alpha + result.b * (1.0f - alpha);
        result.a = alpha + result.a * (1.0f - alpha);
    }
    return packedColor(result);
}

std::shared_ptr<WindowsGpuSurface> GpuRendererImpl::createSurface(HWND hwnd) {
    if (!hwnd) return nullptr;
    return std::make_shared<GpuSurfaceImpl>(shared_from_this(), hwnd);
}

} // namespace

std::shared_ptr<WindowsGpuRenderer> createWindowsGpuRenderer() {
    auto renderer = std::make_shared<GpuRendererImpl>();
    if (!renderer->initialize()) return nullptr;
    return renderer;
}
