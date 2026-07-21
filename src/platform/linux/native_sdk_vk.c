/* Vulkan GPU-surface presenter — see native_sdk_vk.h for the design.
 *
 * Structure mirrors the macOS Metal renderer (appkit_host.m): a host-global
 * context (device/queue/pipeline, the Metal MTLDevice/commandQueue/pipeline
 * analog) plus a per-view renderer (swapchain + canvas image + sync, the
 * CAMetalLayer/drawable analog). The presenter is one full-screen textured
 * quad sampling the canvas image, exactly like ensureCanvasPresenter's
 * native_sdk_canvas_vertex/fragment. */

#include "native_sdk_vk.h"

#define VK_USE_PLATFORM_WAYLAND_KHR
#define VK_USE_PLATFORM_XLIB_KHR
#include <vulkan/vulkan.h>

#include <gtk/gtk.h>
#include <gdk/wayland/gdkwayland.h>
#include <gdk/x11/gdkx.h>
#include <wayland-client.h>

#include <shaderc/shaderc.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define NATIVE_SDK_VK_MAX_SWAP_IMAGES 8

/* ── Inline shaders (compiled to SPIR-V at context creation, the analog of
 * Metal's newLibraryWithSource on inline MSL). Full-screen triangle; the
 * fragment samples the straight-alpha canvas and presents it opaque. Vulkan
 * clip-space Y points down, so uv.y already matches the canvas row order —
 * no flip. ── */
static const char *NATIVE_SDK_VK_VERT_GLSL =
    "#version 450\n"
    "layout(location = 0) out vec2 v_uv;\n"
    "void main() {\n"
    "    vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);\n"
    "    v_uv = uv;\n"
    "    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

static const char *NATIVE_SDK_VK_FRAG_GLSL =
    "#version 450\n"
    "layout(location = 0) in vec2 v_uv;\n"
    "layout(location = 0) out vec4 o_color;\n"
    "layout(binding = 0) uniform sampler2D u_canvas;\n"
    "void main() {\n"
    "    o_color = vec4(texture(u_canvas, v_uv).rgb, 1.0);\n"
    "}\n";

struct native_sdk_vk_context {
    VkInstance instance;
    VkPhysicalDevice phys;
    uint32_t queue_family;
    VkDevice device;
    VkQueue queue;
    VkCommandPool cmd_pool;
    VkRenderPass render_pass;         /* single BGRA8 attachment, clear→present */
    VkDescriptorSetLayout set_layout; /* binding 0: combined image sampler */
    VkDescriptorPool desc_pool;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;              /* full-screen presenter */
    VkSampler sampler;               /* nearest, clamp — canvas is at device scale */
};

struct native_sdk_vk_view {
    native_sdk_vk_context_t *ctx;
    native_sdk_vk_backend_t backend;

    /* Native child surface the swapchain scans out to. */
    struct wl_surface *wl_child;
    struct wl_subsurface *wl_sub;
    struct wl_compositor *wl_comp;
    struct wl_subcompositor *wl_subcomp;
    Display *x_display;
    Window x_child;

    VkSurfaceKHR surface;

    /* Swapchain + framebuffers (recreated on resize / out-of-date). */
    VkSwapchainKHR swapchain;
    VkFormat sc_format;
    VkExtent2D extent;
    uint32_t image_count;
    VkImage images[NATIVE_SDK_VK_MAX_SWAP_IMAGES];
    VkImageView views[NATIVE_SDK_VK_MAX_SWAP_IMAGES];
    VkFramebuffer framebuffers[NATIVE_SDK_VK_MAX_SWAP_IMAGES];

    /* Canvas image (RGBA8, uploaded from the reference renderer's pixels). */
    uint32_t canvas_w, canvas_h;
    VkImage canvas;
    VkDeviceMemory canvas_mem;
    VkImageView canvas_view;
    VkBuffer staging;
    VkDeviceMemory staging_mem;
    VkDeviceSize staging_size;
    VkDescriptorSet desc_set;
    int canvas_ready; /* first upload transitioned the image into SHADER_READ */

    /* Single frame in flight. */
    VkCommandBuffer cmd;
    VkSemaphore acquire_sem;
    VkSemaphore render_sem;
    VkFence fence;

    int px_width, px_height;
    double scale;
};

/* ── helpers ── */

static uint32_t native_sdk_vk_find_memory(native_sdk_vk_context_t *ctx, uint32_t type_bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(ctx->phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    }
    return UINT32_MAX;
}

static VkShaderModule native_sdk_vk_compile(native_sdk_vk_context_t *ctx, shaderc_compiler_t compiler, const char *src, shaderc_shader_kind kind, const char *name) {
    shaderc_compilation_result_t res = shaderc_compile_into_spv(compiler, src, strlen(src), kind, name, "main", NULL);
    if (!res || shaderc_result_get_compilation_status(res) != shaderc_compilation_status_success) {
        if (res) {
            fprintf(stderr, "native-sdk vk: %s shader compile failed: %s\n", name, shaderc_result_get_error_message(res));
            shaderc_result_release(res);
        }
        return VK_NULL_HANDLE;
    }
    VkShaderModuleCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = shaderc_result_get_length(res),
        .pCode = (const uint32_t *)shaderc_result_get_bytes(res),
    };
    VkShaderModule mod = VK_NULL_HANDLE;
    if (vkCreateShaderModule(ctx->device, &ci, NULL, &mod) != VK_SUCCESS) mod = VK_NULL_HANDLE;
    shaderc_result_release(res);
    return mod;
}

/* ── context ── */

native_sdk_vk_context_t *native_sdk_vk_context_create(void) {
    native_sdk_vk_context_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    const char *inst_exts[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
        VK_KHR_XLIB_SURFACE_EXTENSION_NAME,
    };
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "native-sdk",
        .apiVersion = VK_API_VERSION_1_1,
    };
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = 3,
        .ppEnabledExtensionNames = inst_exts,
    };
    if (vkCreateInstance(&ici, NULL, &ctx->instance) != VK_SUCCESS) {
        free(ctx);
        return NULL;
    }

    /* Pick the first device with a graphics queue family. Present support is
     * confirmed per-surface at swapchain creation. */
    uint32_t dev_count = 0;
    vkEnumeratePhysicalDevices(ctx->instance, &dev_count, NULL);
    if (dev_count == 0) goto fail;
    if (dev_count > 8) dev_count = 8;
    VkPhysicalDevice devs[8];
    vkEnumeratePhysicalDevices(ctx->instance, &dev_count, devs);
    ctx->phys = VK_NULL_HANDLE;
    for (uint32_t d = 0; d < dev_count && ctx->phys == VK_NULL_HANDLE; d++) {
        uint32_t qn = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devs[d], &qn, NULL);
        if (qn == 0 || qn > 16) continue;
        VkQueueFamilyProperties qf[16];
        vkGetPhysicalDeviceQueueFamilyProperties(devs[d], &qn, qf);
        for (uint32_t q = 0; q < qn; q++) {
            if (qf[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                ctx->phys = devs[d];
                ctx->queue_family = q;
                break;
            }
        }
    }
    if (ctx->phys == VK_NULL_HANDLE) goto fail;

    const float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = ctx->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &prio,
    };
    const char *dev_exts[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = dev_exts,
    };
    if (vkCreateDevice(ctx->phys, &dci, NULL, &ctx->device) != VK_SUCCESS) goto fail;
    vkGetDeviceQueue(ctx->device, ctx->queue_family, 0, &ctx->queue);

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = ctx->queue_family,
    };
    if (vkCreateCommandPool(ctx->device, &cpci, NULL, &ctx->cmd_pool) != VK_SUCCESS) goto fail;

    /* Render pass: one BGRA8 attachment, clear on load, present when done. */
    VkAttachmentDescription att = {
        .format = VK_FORMAT_B8G8R8A8_UNORM,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    VkAttachmentReference att_ref = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &att_ref,
    };
    VkSubpassDependency dep = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };
    VkRenderPassCreateInfo rpci = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &att,
        .subpassCount = 1, .pSubpasses = &sub,
        .dependencyCount = 1, .pDependencies = &dep,
    };
    if (vkCreateRenderPass(ctx->device, &rpci, NULL, &ctx->render_pass) != VK_SUCCESS) goto fail;

    VkDescriptorSetLayoutBinding bind = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    VkDescriptorSetLayoutCreateInfo dslci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1, .pBindings = &bind,
    };
    if (vkCreateDescriptorSetLayout(ctx->device, &dslci, NULL, &ctx->set_layout) != VK_SUCCESS) goto fail;

    VkDescriptorPoolSize psize = { .type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 16 };
    VkDescriptorPoolCreateInfo dpci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 16, .poolSizeCount = 1, .pPoolSizes = &psize,
    };
    if (vkCreateDescriptorPool(ctx->device, &dpci, NULL, &ctx->desc_pool) != VK_SUCCESS) goto fail;

    VkPipelineLayoutCreateInfo plci = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &ctx->set_layout,
    };
    if (vkCreatePipelineLayout(ctx->device, &plci, NULL, &ctx->pipeline_layout) != VK_SUCCESS) goto fail;

    VkSamplerCreateInfo sci = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    if (vkCreateSampler(ctx->device, &sci, NULL, &ctx->sampler) != VK_SUCCESS) goto fail;

    /* Compile + link the presenter pipeline. */
    shaderc_compiler_t compiler = shaderc_compiler_initialize();
    if (!compiler) goto fail;
    VkShaderModule vs = native_sdk_vk_compile(ctx, compiler, NATIVE_SDK_VK_VERT_GLSL, shaderc_vertex_shader, "presenter.vert");
    VkShaderModule fs = native_sdk_vk_compile(ctx, compiler, NATIVE_SDK_VK_FRAG_GLSL, shaderc_fragment_shader, "presenter.frag");
    shaderc_compiler_release(compiler);
    if (vs == VK_NULL_HANDLE || fs == VK_NULL_HANDLE) {
        if (vs) vkDestroyShaderModule(ctx->device, vs, NULL);
        if (fs) vkDestroyShaderModule(ctx->device, fs, NULL);
        goto fail;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
    };
    VkPipelineVertexInputStateCreateInfo vin = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
    VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f };
    VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
    VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT };
    VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba };
    VkDynamicState dyns[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dyn = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dyns };
    VkGraphicsPipelineCreateInfo gpci = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2, .pStages = stages,
        .pVertexInputState = &vin, .pInputAssemblyState = &ia,
        .pViewportState = &vp, .pRasterizationState = &rs,
        .pMultisampleState = &ms, .pColorBlendState = &cb,
        .pDynamicState = &dyn, .layout = ctx->pipeline_layout,
        .renderPass = ctx->render_pass, .subpass = 0,
    };
    VkResult pr = vkCreateGraphicsPipelines(ctx->device, VK_NULL_HANDLE, 1, &gpci, NULL, &ctx->pipeline);
    vkDestroyShaderModule(ctx->device, vs, NULL);
    vkDestroyShaderModule(ctx->device, fs, NULL);
    if (pr != VK_SUCCESS) goto fail;

    return ctx;

fail:
    native_sdk_vk_context_destroy(ctx);
    return NULL;
}

void native_sdk_vk_context_destroy(native_sdk_vk_context_t *ctx) {
    if (!ctx) return;
    if (ctx->device) {
        vkDeviceWaitIdle(ctx->device);
        if (ctx->pipeline) vkDestroyPipeline(ctx->device, ctx->pipeline, NULL);
        if (ctx->pipeline_layout) vkDestroyPipelineLayout(ctx->device, ctx->pipeline_layout, NULL);
        if (ctx->sampler) vkDestroySampler(ctx->device, ctx->sampler, NULL);
        if (ctx->desc_pool) vkDestroyDescriptorPool(ctx->device, ctx->desc_pool, NULL);
        if (ctx->set_layout) vkDestroyDescriptorSetLayout(ctx->device, ctx->set_layout, NULL);
        if (ctx->render_pass) vkDestroyRenderPass(ctx->device, ctx->render_pass, NULL);
        if (ctx->cmd_pool) vkDestroyCommandPool(ctx->device, ctx->cmd_pool, NULL);
        vkDestroyDevice(ctx->device, NULL);
    }
    if (ctx->instance) vkDestroyInstance(ctx->instance, NULL);
    free(ctx);
}

/* ── swapchain ── */

static void native_sdk_vk_destroy_swapchain(native_sdk_vk_view_t *v) {
    native_sdk_vk_context_t *ctx = v->ctx;
    for (uint32_t i = 0; i < v->image_count; i++) {
        if (v->framebuffers[i]) vkDestroyFramebuffer(ctx->device, v->framebuffers[i], NULL);
        if (v->views[i]) vkDestroyImageView(ctx->device, v->views[i], NULL);
        v->framebuffers[i] = VK_NULL_HANDLE;
        v->views[i] = VK_NULL_HANDLE;
    }
    v->image_count = 0;
    if (v->swapchain) {
        vkDestroySwapchainKHR(ctx->device, v->swapchain, NULL);
        v->swapchain = VK_NULL_HANDLE;
    }
}

static int native_sdk_vk_build_swapchain(native_sdk_vk_view_t *v, uint32_t w, uint32_t h) {
    native_sdk_vk_context_t *ctx = v->ctx;

    VkBool32 present_ok = VK_FALSE;
    vkGetPhysicalDeviceSurfaceSupportKHR(ctx->phys, ctx->queue_family, v->surface, &present_ok);
    if (!present_ok) return 0;

    VkSurfaceCapabilitiesKHR caps;
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx->phys, v->surface, &caps) != VK_SUCCESS) return 0;

    VkExtent2D ext = { w, h };
    if (caps.currentExtent.width != 0xFFFFFFFFu) ext = caps.currentExtent;
    if (ext.width < caps.minImageExtent.width) ext.width = caps.minImageExtent.width;
    if (ext.height < caps.minImageExtent.height) ext.height = caps.minImageExtent.height;
    if (ext.width > caps.maxImageExtent.width) ext.width = caps.maxImageExtent.width;
    if (ext.height > caps.maxImageExtent.height) ext.height = caps.maxImageExtent.height;
    if (ext.width == 0 || ext.height == 0) return 0;

    uint32_t want = caps.minImageCount + 1;
    if (caps.maxImageCount != 0 && want > caps.maxImageCount) want = caps.maxImageCount;
    if (want > NATIVE_SDK_VK_MAX_SWAP_IMAGES) want = NATIVE_SDK_VK_MAX_SWAP_IMAGES;

    VkSwapchainKHR old = v->swapchain;
    VkSwapchainCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = v->surface,
        .minImageCount = want,
        .imageFormat = VK_FORMAT_B8G8R8A8_UNORM,
        .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = ext,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
        .oldSwapchain = old,
    };
    VkSwapchainKHR chain = VK_NULL_HANDLE;
    if (vkCreateSwapchainKHR(ctx->device, &sci, NULL, &chain) != VK_SUCCESS) return 0;

    /* Tear down the old chain's framebuffers/views now that the new chain owns
     * the surface; the old handle was consumed via oldSwapchain. */
    for (uint32_t i = 0; i < v->image_count; i++) {
        if (v->framebuffers[i]) vkDestroyFramebuffer(ctx->device, v->framebuffers[i], NULL);
        if (v->views[i]) vkDestroyImageView(ctx->device, v->views[i], NULL);
        v->framebuffers[i] = VK_NULL_HANDLE;
        v->views[i] = VK_NULL_HANDLE;
    }
    if (old) vkDestroySwapchainKHR(ctx->device, old, NULL);
    v->swapchain = chain;
    v->sc_format = VK_FORMAT_B8G8R8A8_UNORM;
    v->extent = ext;

    uint32_t n = 0;
    vkGetSwapchainImagesKHR(ctx->device, chain, &n, NULL);
    if (n > NATIVE_SDK_VK_MAX_SWAP_IMAGES) n = NATIVE_SDK_VK_MAX_SWAP_IMAGES;
    vkGetSwapchainImagesKHR(ctx->device, chain, &n, v->images);
    v->image_count = n;

    for (uint32_t i = 0; i < n; i++) {
        VkImageViewCreateInfo ivci = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = v->images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = v->sc_format,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        if (vkCreateImageView(ctx->device, &ivci, NULL, &v->views[i]) != VK_SUCCESS) return 0;
        VkFramebufferCreateInfo fbci = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = ctx->render_pass,
            .attachmentCount = 1, .pAttachments = &v->views[i],
            .width = ext.width, .height = ext.height, .layers = 1,
        };
        if (vkCreateFramebuffer(ctx->device, &fbci, NULL, &v->framebuffers[i]) != VK_SUCCESS) return 0;
    }
    return 1;
}

/* ── canvas image (the uploaded pixels) ── */

static void native_sdk_vk_destroy_canvas(native_sdk_vk_view_t *v) {
    native_sdk_vk_context_t *ctx = v->ctx;
    if (v->canvas_view) vkDestroyImageView(ctx->device, v->canvas_view, NULL);
    if (v->canvas) vkDestroyImage(ctx->device, v->canvas, NULL);
    if (v->canvas_mem) vkFreeMemory(ctx->device, v->canvas_mem, NULL);
    if (v->staging) vkDestroyBuffer(ctx->device, v->staging, NULL);
    if (v->staging_mem) vkFreeMemory(ctx->device, v->staging_mem, NULL);
    v->canvas_view = VK_NULL_HANDLE;
    v->canvas = VK_NULL_HANDLE;
    v->canvas_mem = VK_NULL_HANDLE;
    v->staging = VK_NULL_HANDLE;
    v->staging_mem = VK_NULL_HANDLE;
    v->staging_size = 0;
    v->canvas_w = v->canvas_h = 0;
    v->canvas_ready = 0;
}

static int native_sdk_vk_build_canvas(native_sdk_vk_view_t *v, uint32_t w, uint32_t h) {
    native_sdk_vk_context_t *ctx = v->ctx;
    native_sdk_vk_destroy_canvas(v);

    VkImageCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = { w, h, 1 },
        .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (vkCreateImage(ctx->device, &ici, NULL, &v->canvas) != VK_SUCCESS) return 0;

    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(ctx->device, v->canvas, &mr);
    uint32_t mt = native_sdk_vk_find_memory(ctx, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mt == UINT32_MAX) return 0;
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = mt };
    if (vkAllocateMemory(ctx->device, &mai, NULL, &v->canvas_mem) != VK_SUCCESS) return 0;
    vkBindImageMemory(ctx->device, v->canvas, v->canvas_mem, 0);

    VkImageViewCreateInfo ivci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = v->canvas, .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    if (vkCreateImageView(ctx->device, &ivci, NULL, &v->canvas_view) != VK_SUCCESS) return 0;

    VkDeviceSize bytes = (VkDeviceSize)w * h * 4;
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bytes, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    if (vkCreateBuffer(ctx->device, &bci, NULL, &v->staging) != VK_SUCCESS) return 0;
    VkMemoryRequirements bmr;
    vkGetBufferMemoryRequirements(ctx->device, v->staging, &bmr);
    uint32_t bmt = native_sdk_vk_find_memory(ctx, bmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (bmt == UINT32_MAX) return 0;
    VkMemoryAllocateInfo bmai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = bmr.size, .memoryTypeIndex = bmt };
    if (vkAllocateMemory(ctx->device, &bmai, NULL, &v->staging_mem) != VK_SUCCESS) return 0;
    vkBindBufferMemory(ctx->device, v->staging, v->staging_mem, 0);
    v->staging_size = bmr.size;

    VkDescriptorImageInfo dii = { .sampler = ctx->sampler, .imageView = v->canvas_view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkWriteDescriptorSet w0 = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = v->desc_set, .dstBinding = 0,
        .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &dii,
    };
    vkUpdateDescriptorSets(ctx->device, 1, &w0, 0, NULL);

    v->canvas_w = w;
    v->canvas_h = h;
    v->canvas_ready = 0;
    return 1;
}

/* ── view lifecycle ── */

/* Wayland registry: bind the compositor + subcompositor this view needs to
 * create and stack its own subsurface. */
static void native_sdk_vk_registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    native_sdk_vk_view_t *v = data;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        v->wl_comp = wl_registry_bind(reg, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(iface, wl_subcompositor_interface.name) == 0) {
        v->wl_subcomp = wl_registry_bind(reg, name, &wl_subcompositor_interface, 1);
    }
}
static void native_sdk_vk_registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener native_sdk_vk_registry_listener = {
    .global = native_sdk_vk_registry_global,
    .global_remove = native_sdk_vk_registry_global_remove,
};

static int native_sdk_vk_view_init_gpu(native_sdk_vk_view_t *v) {
    native_sdk_vk_context_t *ctx = v->ctx;
    VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = ctx->cmd_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    if (vkAllocateCommandBuffers(ctx->device, &cbai, &v->cmd) != VK_SUCCESS) return 0;
    VkSemaphoreCreateInfo semci = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    if (vkCreateSemaphore(ctx->device, &semci, NULL, &v->acquire_sem) != VK_SUCCESS) return 0;
    if (vkCreateSemaphore(ctx->device, &semci, NULL, &v->render_sem) != VK_SUCCESS) return 0;
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
    if (vkCreateFence(ctx->device, &fci, NULL, &v->fence) != VK_SUCCESS) return 0;
    VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = ctx->desc_pool, .descriptorSetCount = 1, .pSetLayouts = &ctx->set_layout };
    if (vkAllocateDescriptorSets(ctx->device, &dsai, &v->desc_set) != VK_SUCCESS) return 0;
    return 1;
}

native_sdk_vk_view_t *native_sdk_vk_view_create(native_sdk_vk_context_t *ctx, GdkSurface *gdk_surface, int x, int y, int width, int height, double scale) {
    if (!ctx || !gdk_surface || width <= 0 || height <= 0) return NULL;
    native_sdk_vk_view_t *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->ctx = ctx;
    v->scale = scale > 0 ? scale : 1.0;
    v->px_width = (int)(width * v->scale + 0.5);
    v->px_height = (int)(height * v->scale + 0.5);

    if (GDK_IS_WAYLAND_SURFACE(gdk_surface)) {
        GdkDisplay *disp = gdk_surface_get_display(gdk_surface);
        struct wl_display *wl = gdk_wayland_display_get_wl_display(GDK_WAYLAND_DISPLAY(disp));
        struct wl_surface *parent = gdk_wayland_surface_get_wl_surface(GDK_WAYLAND_SURFACE(gdk_surface));
        if (!wl || !parent) goto fail;
        /* Bind wl_compositor + wl_subcompositor from a one-shot registry pass
         * (GTK owns its own binds; ours are private to this view's subsurface). */
        struct wl_registry *reg = wl_display_get_registry(wl);
        if (!reg) goto fail;
        wl_registry_add_listener(reg, &native_sdk_vk_registry_listener, v);
        wl_display_roundtrip(wl);
        wl_registry_destroy(reg);
        if (!v->wl_comp || !v->wl_subcomp) goto fail;

        v->wl_child = wl_compositor_create_surface(v->wl_comp);
        if (!v->wl_child) goto fail;
        struct wl_region *empty = wl_compositor_create_region(v->wl_comp);
        wl_surface_set_input_region(v->wl_child, empty);
        wl_region_destroy(empty);
        v->wl_sub = wl_subcompositor_get_subsurface(v->wl_subcomp, v->wl_child, parent);
        if (!v->wl_sub) goto fail;
        wl_subsurface_set_position(v->wl_sub, x, y);
        wl_subsurface_set_desync(v->wl_sub);
        wl_surface_commit(v->wl_child);

        VkWaylandSurfaceCreateInfoKHR ci = { .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, .display = wl, .surface = v->wl_child };
        if (vkCreateWaylandSurfaceKHR(ctx->instance, &ci, NULL, &v->surface) != VK_SUCCESS) goto fail;
        v->backend = NATIVE_SDK_VK_BACKEND_WAYLAND;
    } else if (GDK_IS_X11_SURFACE(gdk_surface)) {
        GdkDisplay *disp = gdk_surface_get_display(gdk_surface);
        v->x_display = gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(disp));
        Window parent = gdk_x11_surface_get_xid(gdk_surface);
        if (!v->x_display || parent == 0) goto fail;
        v->x_child = XCreateSimpleWindow(v->x_display, parent, x, y, (unsigned)v->px_width, (unsigned)v->px_height, 0, 0, 0);
        if (v->x_child == 0) goto fail;
        XSelectInput(v->x_display, v->x_child, 0); /* input falls through to GTK */
        XMapWindow(v->x_display, v->x_child);
        XFlush(v->x_display);
        VkXlibSurfaceCreateInfoKHR ci = { .sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR, .dpy = v->x_display, .window = v->x_child };
        if (vkCreateXlibSurfaceKHR(ctx->instance, &ci, NULL, &v->surface) != VK_SUCCESS) goto fail;
        v->backend = NATIVE_SDK_VK_BACKEND_X11;
    } else {
        goto fail;
    }

    if (!native_sdk_vk_view_init_gpu(v)) goto fail;
    if (!native_sdk_vk_build_swapchain(v, (uint32_t)v->px_width, (uint32_t)v->px_height)) goto fail;
    /* NATIVE_SDK_VK_DIAG=1: one line per view bring-up, mirroring the host's
     * NATIVE_SDK_GSK_DIAG — confirms which backend owns the glass. */
    if (getenv("NATIVE_SDK_VK_DIAG")) {
        fprintf(stderr, "native-sdk vk: %s surface up, swapchain %ux%u (%u images)\n",
                v->backend == NATIVE_SDK_VK_BACKEND_WAYLAND ? "wayland" : "x11",
                v->extent.width, v->extent.height, v->image_count);
    }
    return v;

fail:
    native_sdk_vk_view_destroy(v);
    return NULL;
}

void native_sdk_vk_view_destroy(native_sdk_vk_view_t *v) {
    if (!v) return;
    native_sdk_vk_context_t *ctx = v->ctx;
    if (ctx && ctx->device) vkDeviceWaitIdle(ctx->device);
    native_sdk_vk_destroy_canvas(v);
    native_sdk_vk_destroy_swapchain(v);
    if (ctx && ctx->device) {
        if (v->fence) vkDestroyFence(ctx->device, v->fence, NULL);
        if (v->acquire_sem) vkDestroySemaphore(ctx->device, v->acquire_sem, NULL);
        if (v->render_sem) vkDestroySemaphore(ctx->device, v->render_sem, NULL);
        if (v->desc_set) vkFreeDescriptorSets(ctx->device, ctx->desc_pool, 1, &v->desc_set);
        if (v->cmd) vkFreeCommandBuffers(ctx->device, ctx->cmd_pool, 1, &v->cmd);
    }
    if (v->surface && ctx) vkDestroySurfaceKHR(ctx->instance, v->surface, NULL);
    if (v->wl_sub) wl_subsurface_destroy(v->wl_sub);
    if (v->wl_child) wl_surface_destroy(v->wl_child);
    if (v->wl_subcomp) wl_subcompositor_destroy(v->wl_subcomp);
    if (v->wl_comp) wl_compositor_destroy(v->wl_comp);
    if (v->x_child && v->x_display) {
        XDestroyWindow(v->x_display, v->x_child);
        XFlush(v->x_display);
    }
    free(v);
}

void native_sdk_vk_view_set_geometry(native_sdk_vk_view_t *v, int x, int y, int width, int height, double scale) {
    if (!v) return;
    v->scale = scale > 0 ? scale : 1.0;
    int pw = (int)(width * v->scale + 0.5);
    int ph = (int)(height * v->scale + 0.5);
    if (v->backend == NATIVE_SDK_VK_BACKEND_WAYLAND && v->wl_sub) {
        wl_subsurface_set_position(v->wl_sub, x, y);
        if (v->wl_child) wl_surface_commit(v->wl_child);
    } else if (v->backend == NATIVE_SDK_VK_BACKEND_X11 && v->x_display && v->x_child) {
        XMoveResizeWindow(v->x_display, v->x_child, x, y, (unsigned)(pw > 0 ? pw : 1), (unsigned)(ph > 0 ? ph : 1));
        XFlush(v->x_display);
    }
    if (pw != v->px_width || ph != v->px_height) {
        v->px_width = pw;
        v->px_height = ph;
        if (v->ctx->device) vkDeviceWaitIdle(v->ctx->device);
        native_sdk_vk_build_swapchain(v, (uint32_t)(pw > 0 ? pw : 1), (uint32_t)(ph > 0 ? ph : 1));
    }
}

native_sdk_vk_backend_t native_sdk_vk_view_backend(const native_sdk_vk_view_t *v) {
    return v ? v->backend : NATIVE_SDK_VK_BACKEND_NONE;
}

/* ── present ── */

static void native_sdk_vk_barrier(VkCommandBuffer cmd, VkImage img, VkImageLayout from, VkImageLayout to, VkAccessFlags src_access, VkAccessFlags dst_access, VkPipelineStageFlags src_stage, VkPipelineStageFlags dst_stage) {
    VkImageMemoryBarrier b = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = from, .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = img,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcAccessMask = src_access, .dstAccessMask = dst_access,
    };
    vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, NULL, 0, NULL, 1, &b);
}

int native_sdk_vk_view_present_pixels(native_sdk_vk_view_t *v, const uint8_t *rgba8, uint32_t width, uint32_t height) {
    if (!v || !rgba8 || width == 0 || height == 0) return 0;
    native_sdk_vk_context_t *ctx = v->ctx;
    if (v->swapchain == VK_NULL_HANDLE && !native_sdk_vk_build_swapchain(v, width, height)) return 0;

    if (v->canvas == VK_NULL_HANDLE || v->canvas_w != width || v->canvas_h != height) {
        if (ctx->device) vkDeviceWaitIdle(ctx->device);
        if (!native_sdk_vk_build_canvas(v, width, height)) return 0;
    }

    vkWaitForFences(ctx->device, 1, &v->fence, VK_TRUE, UINT64_MAX);

    uint32_t image_index = 0;
    VkResult ar = vkAcquireNextImageKHR(ctx->device, v->swapchain, UINT64_MAX, v->acquire_sem, VK_NULL_HANDLE, &image_index);
    if (ar == VK_ERROR_OUT_OF_DATE_KHR) {
        native_sdk_vk_build_swapchain(v, v->px_width > 0 ? (uint32_t)v->px_width : width, v->px_height > 0 ? (uint32_t)v->px_height : height);
        return 0;
    }
    if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) return 0;

    vkResetFences(ctx->device, 1, &v->fence);

    /* Upload the RGBA pixels into staging. */
    void *mapped = NULL;
    VkDeviceSize bytes = (VkDeviceSize)width * height * 4;
    if (vkMapMemory(ctx->device, v->staging_mem, 0, bytes, 0, &mapped) != VK_SUCCESS) return 0;
    memcpy(mapped, rgba8, (size_t)bytes);
    vkUnmapMemory(ctx->device, v->staging_mem);

    vkResetCommandBuffer(v->cmd, 0);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(v->cmd, &bi);

    /* Copy staging → canvas image. */
    VkImageLayout from = v->canvas_ready ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
    native_sdk_vk_barrier(v->cmd, v->canvas, from, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                          v->canvas_ready ? VK_ACCESS_SHADER_READ_BIT : 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                          VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy region = {
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageExtent = { width, height, 1 },
    };
    vkCmdCopyBufferToImage(v->cmd, v->staging, v->canvas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    native_sdk_vk_barrier(v->cmd, v->canvas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                          VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
                          VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    v->canvas_ready = 1;

    /* Present pass: full-screen quad sampling the canvas. */
    VkClearValue clear = { .color = { { 0.0f, 0.0f, 0.0f, 1.0f } } };
    VkRenderPassBeginInfo rbi = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = ctx->render_pass,
        .framebuffer = v->framebuffers[image_index],
        .renderArea = { { 0, 0 }, v->extent },
        .clearValueCount = 1, .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(v->cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport vp = { 0, 0, (float)v->extent.width, (float)v->extent.height, 0.0f, 1.0f };
    VkRect2D sc = { { 0, 0 }, v->extent };
    vkCmdSetViewport(v->cmd, 0, 1, &vp);
    vkCmdSetScissor(v->cmd, 0, 1, &sc);
    vkCmdBindPipeline(v->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ctx->pipeline);
    vkCmdBindDescriptorSets(v->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ctx->pipeline_layout, 0, 1, &v->desc_set, 0, NULL);
    vkCmdDraw(v->cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(v->cmd);
    vkEndCommandBuffer(v->cmd);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &v->acquire_sem, .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1, .pCommandBuffers = &v->cmd,
        .signalSemaphoreCount = 1, .pSignalSemaphores = &v->render_sem,
    };
    if (vkQueueSubmit(ctx->queue, 1, &si, v->fence) != VK_SUCCESS) return 0;

    VkPresentInfoKHR pi = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &v->render_sem,
        .swapchainCount = 1, .pSwapchains = &v->swapchain, .pImageIndices = &image_index,
    };
    VkResult pr = vkQueuePresentKHR(ctx->queue, &pi);
    if (pr == VK_ERROR_OUT_OF_DATE_KHR || pr == VK_SUBOPTIMAL_KHR) {
        native_sdk_vk_build_swapchain(v, v->px_width > 0 ? (uint32_t)v->px_width : width, v->px_height > 0 ? (uint32_t)v->px_height : height);
    }
    return 1;
}
