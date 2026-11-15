#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <vulkan/vulkan.h>
#include <libplacebo/vulkan.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_vk.h>

#define WIDTH 3840
#define HEIGHT 2160

typedef struct {
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    uint32_t graphics_family;
    VkQueue graphics;
    const char *extensions[64];
    int extension_count;
    VkPhysicalDeviceFeatures2 features;
    VkPhysicalDeviceVulkan11Features v11;
    VkPhysicalDeviceVulkan12Features v12;
    VkPhysicalDeviceVulkan13Features v13;
    VkCommandPool pool;
    VkImage image;
    VkDeviceMemory image_memory;
    VkImageView view;
    VkBuffer readback;
    VkDeviceMemory readback_memory;
    VkQueryPool timestamps;
    float timestamp_period;
} host;

static double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static bool device_has(VkExtensionProperties *available, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; i++)
        if (strcmp(available[i].extensionName, name) == 0) return true;
    return false;
}

static void add_extension(host *h, VkExtensionProperties *available, uint32_t count, const char *name) {
    if (!device_has(available, count, name)) return;
    for (int i = 0; i < h->extension_count; i++)
        if (strcmp(h->extensions[i], name) == 0) return;
    h->extensions[h->extension_count++] = name;
}

static uint32_t memory_type(host *h, uint32_t bits, VkMemoryPropertyFlags wanted) {
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(h->physical, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) return i;
    return 0;
}

/** Creates the instance and a device the way Kiln will: one graphics queue, every libplacebo-recommended extension the
 * GPU offers plus external memory, external semaphores and Vulkan Video decode, and every core 1.1 to 1.3 feature. */
static bool create_device(host *h) {
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "kiln", .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo instance_info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    if (vkCreateInstance(&instance_info, NULL, &h->instance) != VK_SUCCESS) return false;
    uint32_t count = 1;
    vkEnumeratePhysicalDevices(h->instance, &count, &h->physical);
    if (count == 0) return false;
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(h->physical, &properties);
    h->timestamp_period = properties.limits.timestampPeriod;
    uint32_t families = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(h->physical, &families, NULL);
    VkQueueFamilyProperties *family = calloc(families, sizeof(*family));
    vkGetPhysicalDeviceQueueFamilyProperties(h->physical, &families, family);
    int decode_family = -1;
    uint32_t decode_count = 0;
    for (uint32_t i = 0; i < families; i++) {
        if (family[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { h->graphics_family = i; break; }
    }
    for (uint32_t i = 0; i < families; i++) {
        if ((family[i].queueFlags & VK_QUEUE_VIDEO_DECODE_BIT_KHR) && i != h->graphics_family) { decode_family = (int)i; decode_count = family[i].queueCount; break; }
    }
    free(family);
    uint32_t available_count = 0;
    vkEnumerateDeviceExtensionProperties(h->physical, NULL, &available_count, NULL);
    VkExtensionProperties *available = calloc(available_count, sizeof(*available));
    vkEnumerateDeviceExtensionProperties(h->physical, NULL, &available_count, available);
    for (int i = 0; i < pl_vulkan_num_recommended_extensions; i++) add_extension(h, available, available_count, pl_vulkan_recommended_extensions[i]);
    const char *extra[] = {
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME, VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        VK_KHR_VIDEO_QUEUE_EXTENSION_NAME, VK_KHR_VIDEO_DECODE_QUEUE_EXTENSION_NAME, VK_KHR_VIDEO_DECODE_H264_EXTENSION_NAME,
        VK_KHR_VIDEO_DECODE_H265_EXTENSION_NAME, VK_KHR_VIDEO_DECODE_AV1_EXTENSION_NAME, VK_KHR_VIDEO_MAINTENANCE_1_EXTENSION_NAME,
    };
    for (size_t i = 0; i < sizeof(extra) / sizeof(*extra); i++) add_extension(h, available, available_count, extra[i]);
    free(available);
    h->v13 = (VkPhysicalDeviceVulkan13Features){ .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    h->v12 = (VkPhysicalDeviceVulkan12Features){ .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &h->v13 };
    h->v11 = (VkPhysicalDeviceVulkan11Features){ .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &h->v12 };
    h->features = (VkPhysicalDeviceFeatures2){ .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &h->v11 };
    vkGetPhysicalDeviceFeatures2(h->physical, &h->features);
    h->features.features.robustBufferAccess = VK_FALSE;
    float priorities[16] = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    VkDeviceQueueCreateInfo queues[2] = {
        { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = h->graphics_family, .queueCount = 1, .pQueuePriorities = priorities },
        { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = (uint32_t)decode_family, .queueCount = decode_count > 16 ? 16 : decode_count, .pQueuePriorities = priorities },
    };
    printf("decodeFamily=%d queues=%u\n", decode_family, decode_count);
    VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &h->features, .queueCreateInfoCount = decode_family >= 0 ? 2 : 1, .pQueueCreateInfos = queues,
        .enabledExtensionCount = (uint32_t)h->extension_count, .ppEnabledExtensionNames = h->extensions,
    };
    if (vkCreateDevice(h->physical, &device_info, NULL, &h->device) != VK_SUCCESS) return false;
    vkGetDeviceQueue(h->device, h->graphics_family, 0, &h->graphics);
    VkCommandPoolCreateInfo pool = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = h->graphics_family };
    vkCreateCommandPool(h->device, &pool, NULL, &h->pool);
    VkQueryPoolCreateInfo query = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 2 };
    vkCreateQueryPool(h->device, &query, NULL, &h->timestamps);
    return true;
}

static bool create_target(host *h) {
    VkImageCreateInfo image = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R16G16B16A16_SFLOAT,
        .extent = { WIDTH, HEIGHT, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (vkCreateImage(h->device, &image, NULL, &h->image) != VK_SUCCESS) return false;
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(h->device, h->image, &requirements);
    VkMemoryAllocateInfo allocate = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = memory_type(h, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    vkAllocateMemory(h->device, &allocate, NULL, &h->image_memory);
    vkBindImageMemory(h->device, h->image, h->image_memory, 0);
    VkImageViewCreateInfo view = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = h->image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R16G16B16A16_SFLOAT,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    vkCreateImageView(h->device, &view, NULL, &h->view);
    VkBufferCreateInfo buffer = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = (VkDeviceSize)WIDTH * HEIGHT * 8, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    vkCreateBuffer(h->device, &buffer, NULL, &h->readback);
    vkGetBufferMemoryRequirements(h->device, h->readback, &requirements);
    allocate.allocationSize = requirements.size;
    allocate.memoryTypeIndex = memory_type(h, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    vkAllocateMemory(h->device, &allocate, NULL, &h->readback_memory);
    vkBindBufferMemory(h->device, h->readback, h->readback_memory, 0);
    return true;
}

static VkCommandBuffer begin_commands(host *h) {
    VkCommandBuffer commands;
    VkCommandBufferAllocateInfo allocate = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = h->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    vkAllocateCommandBuffers(h->device, &allocate, &commands);
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer(commands, &begin);
    return commands;
}

static void submit_and_wait(host *h, VkCommandBuffer commands) {
    vkEndCommandBuffer(commands);
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands };
    vkQueueSubmit(h->graphics, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(h->graphics);
    vkFreeCommandBuffers(h->device, h->pool, 1, &commands);
}

/** Copies the target into the host buffer and returns it as half floats, top row first. */
static const uint16_t *read_target(host *h, VkImageLayout layout) {
    VkCommandBuffer commands = begin_commands(h);
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = layout, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = h->image, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { WIDTH, HEIGHT, 1 } };
    vkCmdCopyImageToBuffer(commands, h->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, h->readback, 1, &region);
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    submit_and_wait(h, commands);
    void *mapped;
    vkMapMemory(h->device, h->readback_memory, 0, VK_WHOLE_SIZE, 0, &mapped);
    return mapped;
}

static float half_to_float(uint16_t h) {
    uint32_t sign = (h >> 15) & 1, exponent = (h >> 10) & 31, mantissa = h & 1023;
    float value = exponent == 0 ? ldexpf((float)mantissa, -24) : exponent == 31 ? INFINITY : ldexpf((float)(mantissa | 1024), (int)exponent - 25);
    return sign ? -value : value;
}

static double pq_to_nits(float value) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128, c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32;
    double e = pow(fmax(value, 0), 1 / m2);
    return 10000 * pow(fmax(e - c1, 0) / (c2 - c3 * e), 1 / m1);
}

static void write_preview(const uint16_t *pixels, const char *path) {
    FILE *file = fopen(path, "wb");
    if (!file) return;
    fprintf(file, "P6\n%d %d\n255\n", WIDTH / 2, HEIGHT / 2);
    for (int y = 0; y < HEIGHT; y += 2) {
        for (int x = 0; x < WIDTH; x += 2) {
            for (int c = 0; c < 3; c++) {
                double linear = fmin(pq_to_nits(half_to_float(pixels[((size_t)y * WIDTH + x) * 4 + c])) / 203, 1);
                double encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055;
                fputc((int)lround(encoded * 255), file);
            }
        }
    }
    fclose(file);
}

static bool wait_for(mpv_handle *mpv, mpv_event_id wanted, double seconds) {
    double deadline = now_seconds() + seconds;
    while (now_seconds() < deadline) {
        mpv_event *event = mpv_wait_event(mpv, 0.1);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            if (getenv("MPV_LOG_ALL") || strstr(message->prefix, "hwdec") || strstr(message->text, "hwdec") || strstr(message->text, "Vulkan") || strstr(message->prefix, "vd"))
                fprintf(stderr, "[%s] %s", message->prefix, message->text);
        }
        if (event->event_id == wanted) return true;
        if (event->event_id == MPV_EVENT_SHUTDOWN) return false;
    }
    return false;
}

/** Renders one frame into the target through mpv's gpu-next Vulkan render API and returns its GPU time in ms. */
static double render(host *h, mpv_render_context *context, VkImageLayout *layout) {
    mpv_vulkan_fbo fbo = {
        .image = h->image, .image_view = h->view, .width = WIDTH, .height = HEIGHT, .format = VK_FORMAT_R16G16B16A16_SFLOAT,
        .current_layout = *layout, .target_layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    int flip = 0;
    int block = 0;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_VULKAN_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flip },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    double started = now_seconds();
    mpv_render_context_render(context, params);
    vkQueueWaitIdle(h->graphics);
    *layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    return (now_seconds() - started) * 1000;
}

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void probe(host *h, const char *path, const char *hwdec, const char *out) {
    const char *slash = strrchr(path, '/');
    char name[256];
    snprintf(name, sizeof(name), "%s", slash ? slash + 1 : path);
    char *dot = strrchr(name, '.');
    if (dot) *dot = 0;
    mpv_handle *mpv = mpv_create();
    const char *options[][2] = {
        { "vo", "libmpv" }, { "hwdec", hwdec }, { "target-trc", "pq" }, { "target-prim", "bt.2020" }, { "target-peak", "10000" },
        { "tone-mapping", "clip" }, { "gamut-mapping-mode", "clip" }, { "hdr-compute-peak", "no" }, { "dither", "no" },
        { "audio", "no" }, { "pause", "yes" }, { "keep-open", "yes" }, { "terminal", "no" },
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(*options); i++) mpv_set_option_string(mpv, options[i][0], options[i][1]);
    if (mpv_initialize(mpv) < 0) { printf("%s.error=mpv init\n", name); return; }
    if (getenv("MPV_LOG")) mpv_request_log_messages(mpv, "debug");
    mpv_vulkan_init_params init = {
        .instance = h->instance, .physical_device = h->physical, .device = h->device, .graphics_queue = h->graphics,
        .graphics_queue_family = h->graphics_family, .get_instance_proc_addr = vkGetInstanceProcAddr, .features = &h->features,
        .extensions = h->extensions, .num_extensions = h->extension_count,
    };
    mpv_render_param create[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)"vulkan" },
        { MPV_RENDER_PARAM_BACKEND, (void *)"gpu-next" },
        { MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, &init },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    mpv_render_context *context = NULL;
    int created = mpv_render_context_create(&context, mpv, create);
    if (created < 0) { printf("%s.error=render context %s\n", name, mpv_error_string(created)); mpv_terminate_destroy(mpv); return; }
    const char *load[] = { "loadfile", path, NULL };
    mpv_command(mpv, load);
    if (!wait_for(mpv, MPV_EVENT_PLAYBACK_RESTART, 15)) { printf("%s.error=no first frame\n", name); }
    VkImageLayout layout = VK_IMAGE_LAYOUT_UNDEFINED;
    for (int i = 0; i < 4; i++) render(h, context, &layout);
    char *current = mpv_get_property_string(mpv, "hwdec-current");
    char *matrix = mpv_get_property_string(mpv, "video-params/colormatrix");
    printf("%s.hwdec=%s colormatrix=%s\n", name, current ? current : "?", matrix ? matrix : "?");
    mpv_free(current);
    mpv_free(matrix);
    const uint16_t *pixels = read_target(h, layout);
    double fractions[] = { 1.0 / 6, 0.5, 5.0 / 6 };
    for (int i = 0; i < 3; i++) {
        size_t index = ((size_t)(HEIGHT / 2) * WIDTH + (size_t)(WIDTH * fractions[i])) * 4;
        printf("%s.sample%d.pq=%.4f,%.4f,%.4f nits=%.1f\n", name, i, half_to_float(pixels[index]), half_to_float(pixels[index + 1]),
               half_to_float(pixels[index + 2]), pq_to_nits(half_to_float(pixels[index + 1])));
    }
    char preview[1024];
    snprintf(preview, sizeof(preview), "%s/%s.ppm", out, name);
    write_preview(pixels, preview);
    vkUnmapMemory(h->device, h->readback_memory);
    mpv_set_property_string(mpv, "pause", "no");
    double times[4096];
    int renders = 0;
    double started = now_seconds();
    while (now_seconds() - started < 4 && renders < 4096) {
        uint64_t flags = mpv_render_context_update(context);
        if (flags & MPV_RENDER_UPDATE_FRAME) times[renders++] = render(h, context, &layout);
        mpv_event *event = mpv_wait_event(mpv, 0.002);
        (void)event;
    }
    qsort(times, renders, sizeof(double), compare_doubles);
    char *drops = mpv_get_property_string(mpv, "frame-drop-count");
    char *decoder = mpv_get_property_string(mpv, "decoder-frame-drop-count");
    if (renders) printf("%s.frames=%d renderWallMsMedian=%.3f renderWallMsP99=%.3f drops=%s decoderDrops=%s\n", name, renders, times[renders / 2], times[renders * 99 / 100], drops ? drops : "?", decoder ? decoder : "?");
    mpv_free(drops);
    mpv_free(decoder);
    mpv_render_context_free(context);
    mpv_terminate_destroy(mpv);
}

int main(int argc, char **argv) {
    host h = { 0 };
    if (!create_device(&h) || !create_target(&h)) { printf("error=vulkan device\n"); return 1; }
    printf("extensions=%d\n", h.extension_count);
    const char *hwdec = getenv("HWDEC") ? getenv("HWDEC") : "vulkan";
    const char *out = getenv("SPIKE_OUT") ? getenv("SPIKE_OUT") : ".";
    for (int i = 1; i < argc; i++) probe(&h, argv[i], hwdec, out);
    return 0;
}
