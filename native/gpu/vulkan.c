// Optional Vulkan 1.0 compute backend. No loader or driver is a link dependency.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

// Load API entry points without incompatible-function casts. All supported
// platform ABIs represent exported function addresses with pointer-sized bits.
#define COPY_ADDRESS(destination, type, expression) do { \
    type address = (expression); \
    _Static_assert(sizeof address == sizeof(destination), "function address size"); \
    memcpy(&(destination), &address, sizeof(destination)); \
} while (0)

#define FUNCTIONS(X) \
 X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties) \
 X(GetPhysicalDeviceQueueFamilyProperties) X(GetPhysicalDeviceMemoryProperties) \
 X(CreateDevice) X(DestroyDevice) X(GetDeviceQueue) X(DeviceWaitIdle) \
 X(CreateShaderModule) X(DestroyShaderModule) X(CreateDescriptorSetLayout) \
 X(DestroyDescriptorSetLayout) X(CreatePipelineLayout) X(DestroyPipelineLayout) \
 X(CreateComputePipelines) X(DestroyPipeline) X(CreateDescriptorPool) \
 X(DestroyDescriptorPool) X(AllocateDescriptorSets) X(UpdateDescriptorSets) \
 X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers) X(ResetCommandPool) \
 X(BeginCommandBuffer) X(EndCommandBuffer) X(CmdBindPipeline) X(CmdBindDescriptorSets) \
 X(CmdPushConstants) X(CmdDispatch) X(CmdPipelineBarrier) X(QueueSubmit) \
 X(CreateFence) X(DestroyFence) X(ResetFences) X(WaitForFences) \
 X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements) X(AllocateMemory) \
 X(FreeMemory) X(BindBufferMemory) X(MapMemory) X(UnmapMemory)

typedef struct Buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapped;
    VkDeviceSize size;
} Buffer;
typedef struct Context {
#ifdef _WIN32
    HMODULE loader;
#else
    void *loader;
#endif
    PFN_vkGetInstanceProcAddr get;
#define DECLARE(name) PFN_vk##name name;
    FUNCTIONS(DECLARE)
#undef DECLARE
    VkInstance instance;
    VkPhysicalDevice physical;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceMemoryProperties memory;
    VkDevice device;
    VkQueue queue;
    VkDescriptorSetLayout descriptor_layout;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipeline;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptor;
    VkCommandPool command_pool;
    VkCommandBuffer command;
    VkFence fence;
    Buffer buffers[4];
    int broken;
} Context;

static void free_buffer(Context *c, Buffer *b) {
    if (b->mapped) c->UnmapMemory(c->device, b->memory);
    if (b->buffer) c->DestroyBuffer(c->device, b->buffer, NULL);
    if (b->memory) c->FreeMemory(c->device, b->memory, NULL);
    memset(b, 0, sizeof *b);
}
void sshdesk_vulkan_destroy(void *pointer) {
    Context *c = pointer;
    if (!c) return;
    if (c->device) {
        c->DeviceWaitIdle(c->device);
        for (unsigned i = 0; i < 4; ++i) free_buffer(c, &c->buffers[i]);
        if (c->fence) c->DestroyFence(c->device, c->fence, NULL);
        if (c->command_pool) c->DestroyCommandPool(c->device, c->command_pool, NULL);
        if (c->descriptor_pool) c->DestroyDescriptorPool(c->device, c->descriptor_pool, NULL);
        if (c->pipeline) c->DestroyPipeline(c->device, c->pipeline, NULL);
        if (c->pipeline_layout) c->DestroyPipelineLayout(c->device, c->pipeline_layout, NULL);
        if (c->descriptor_layout) c->DestroyDescriptorSetLayout(c->device, c->descriptor_layout, NULL);
        c->DestroyDevice(c->device, NULL);
    }
    if (c->instance && c->DestroyInstance) c->DestroyInstance(c->instance, NULL);
    if (c->loader) {
#ifdef _WIN32
        FreeLibrary(c->loader);
#else
        dlclose(c->loader);
#endif
    }
    free(c);
}

void *sshdesk_vulkan_create(const uint32_t *shader, size_t shader_size, int allow_software) {
    Context *c = calloc(1, sizeof *c);
    if (!c) return NULL;
#ifdef _WIN32
    c->loader = LoadLibraryExA("vulkan-1.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (c->loader) {
        // Windows exports untyped function addresses as FARPROC. Copy the
        // pointer representation without an incompatible-function cast.
        COPY_ADDRESS(c->get, FARPROC, GetProcAddress(c->loader, "vkGetInstanceProcAddr"));
    }
#else
    c->loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (c->loader) COPY_ADDRESS(c->get, void *, dlsym(c->loader, "vkGetInstanceProcAddr"));
#endif
    if (!c->get) goto fail;
    PFN_vkCreateInstance create;
    COPY_ADDRESS(create, PFN_vkVoidFunction, c->get(NULL, "vkCreateInstance"));
    if (!create) goto fail;
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "SSHDESK", .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo instance = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    if (create(&instance, NULL, &c->instance) != VK_SUCCESS) goto fail;
#define LOAD(name) COPY_ADDRESS(c->name, PFN_vkVoidFunction, c->get(c->instance, "vk" #name)); if (!c->name) goto fail;
    FUNCTIONS(LOAD)
#undef LOAD
    uint32_t count = 0;
    if (c->EnumeratePhysicalDevices(c->instance, &count, NULL) != VK_SUCCESS || !count || count > 256) goto fail;
    VkPhysicalDevice devices[256];
    if (c->EnumeratePhysicalDevices(c->instance, &count, devices) != VK_SUCCESS) goto fail;
    // Prefer integrated/discrete GPUs; CPU implementations are opt-in for tests.
    for (unsigned tier = 0; tier < (allow_software ? 2u : 1u) && !c->device; ++tier) {
        for (uint32_t i = 0; i < count && !c->device; ++i) {
            VkPhysicalDeviceProperties properties;
            c->GetPhysicalDeviceProperties(devices[i], &properties);
            int hardware = properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU ||
                           properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ||
                           properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU;
            if ((tier == 0) != hardware) continue;
            if (properties.limits.maxComputeWorkGroupInvocations < 64 || properties.limits.maxComputeWorkGroupSize[0] < 64) continue;
            uint32_t families = 0;
            c->GetPhysicalDeviceQueueFamilyProperties(devices[i], &families, NULL);
            if (!families || families > 256) continue;
            VkQueueFamilyProperties queues[256];
            c->GetPhysicalDeviceQueueFamilyProperties(devices[i], &families, queues);
            for (uint32_t family = 0; family < families; ++family) {
                if (!queues[family].queueCount || !(queues[family].queueFlags & VK_QUEUE_COMPUTE_BIT)) continue;
                float priority = 1;
                VkDeviceQueueCreateInfo queue = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
                VkDeviceCreateInfo device = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue };
                if (c->CreateDevice(devices[i], &device, NULL, &c->device) != VK_SUCCESS) { c->device = VK_NULL_HANDLE; continue; }
                c->physical = devices[i];
                c->properties = properties;
                c->GetPhysicalDeviceMemoryProperties(c->physical, &c->memory);
                c->GetDeviceQueue(c->device, family, 0, &c->queue);
                VkCommandPoolCreateInfo pool = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
                if (c->CreateCommandPool(c->device, &pool, NULL, &c->command_pool) != VK_SUCCESS) goto fail;
                break;
            }
        }
    }
    if (!c->device) goto fail;
    VkDescriptorSetLayoutBinding bindings[4] = {0};
    for (unsigned i = 0; i < 4; ++i) bindings[i] = (VkDescriptorSetLayoutBinding){ .binding = i, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT };
    VkDescriptorSetLayoutCreateInfo layout = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 4, .pBindings = bindings };
    if (c->CreateDescriptorSetLayout(c->device, &layout, NULL, &c->descriptor_layout) != VK_SUCCESS) goto fail;
    VkPushConstantRange push = { .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .size = 16 };
    VkPipelineLayoutCreateInfo pipeline_layout = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &c->descriptor_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &push };
    if (c->CreatePipelineLayout(c->device, &pipeline_layout, NULL, &c->pipeline_layout) != VK_SUCCESS) goto fail;
    VkShaderModule module = VK_NULL_HANDLE;
    VkShaderModuleCreateInfo shader_info = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = shader_size, .pCode = shader };
    if (c->CreateShaderModule(c->device, &shader_info, NULL, &module) != VK_SUCCESS) goto fail;
    VkComputePipelineCreateInfo pipeline = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = "main" }, .layout = c->pipeline_layout };
    VkResult result = c->CreateComputePipelines(c->device, VK_NULL_HANDLE, 1, &pipeline, NULL, &c->pipeline);
    c->DestroyShaderModule(c->device, module, NULL);
    if (result != VK_SUCCESS) goto fail;
    VkDescriptorPoolSize pool_size = { .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 4 };
    VkDescriptorPoolCreateInfo pool = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size };
    if (c->CreateDescriptorPool(c->device, &pool, NULL, &c->descriptor_pool) != VK_SUCCESS) goto fail;
    VkDescriptorSetAllocateInfo set = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = c->descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &c->descriptor_layout };
    if (c->AllocateDescriptorSets(c->device, &set, &c->descriptor) != VK_SUCCESS) goto fail;
    VkCommandBufferAllocateInfo command = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = c->command_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    if (c->AllocateCommandBuffers(c->device, &command, &c->command) != VK_SUCCESS) goto fail;
    VkFenceCreateInfo fence = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (c->CreateFence(c->device, &fence, NULL, &c->fence) != VK_SUCCESS) goto fail;
    return c;
fail:
    sshdesk_vulkan_destroy(c);
    return NULL;
}

static int ensure_buffer(Context *c, Buffer *old, VkDeviceSize size) {
    if (old->size >= size) return 1;
    if (size > c->properties.limits.maxStorageBufferRange) return 0;
    Buffer b = {0};
    VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    if (c->CreateBuffer(c->device, &info, NULL, &b.buffer) != VK_SUCCESS) return 0;
    VkMemoryRequirements requirements;
    c->GetBufferMemoryRequirements(c->device, b.buffer, &requirements);
    for (uint32_t i = 0; i < c->memory.memoryTypeCount; ++i) {
        VkMemoryPropertyFlags flags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if (!(requirements.memoryTypeBits & (1u << i)) || (c->memory.memoryTypes[i].propertyFlags & flags) != flags) continue;
        VkMemoryAllocateInfo allocation = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = i };
        if (c->AllocateMemory(c->device, &allocation, NULL, &b.memory) == VK_SUCCESS) break;
    }
    if (!b.memory || c->BindBufferMemory(c->device, b.buffer, b.memory, 0) != VK_SUCCESS ||
        c->MapMemory(c->device, b.memory, 0, VK_WHOLE_SIZE, 0, &b.mapped) != VK_SUCCESS) {
        free_buffer(c, &b);
        return 0;
    }
    b.size = size;
    free_buffer(c, old);
    *old = b;
    return 1;
}

int sshdesk_vulkan_pass(void *pointer, const void *source, size_t source_size,
                       const void *spans, size_t spans_size, const void *weights, size_t weights_size,
                       void *output, uint32_t source_width, uint32_t width, uint32_t height, uint32_t vertical) {
    Context *c = pointer;
    if (c->broken || (width + 63) / 64 > c->properties.limits.maxComputeWorkGroupCount[0] ||
        height > c->properties.limits.maxComputeWorkGroupCount[1]) return 0;
    const VkDeviceSize sizes[4] = { (source_size + 3) & ~(VkDeviceSize)3, spans_size, weights_size, (VkDeviceSize)width * height * 4 };
    VkDescriptorBufferInfo buffers[4];
    VkWriteDescriptorSet writes[4];
    for (unsigned i = 0; i < 4; ++i) {
        if (!ensure_buffer(c, &c->buffers[i], sizes[i])) return 0;
        buffers[i] = (VkDescriptorBufferInfo){ .buffer = c->buffers[i].buffer, .range = sizes[i] };
        writes[i] = (VkWriteDescriptorSet){ .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = c->descriptor, .dstBinding = i, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &buffers[i] };
    }
    memcpy(c->buffers[0].mapped, source, source_size);
    memset((char *)c->buffers[0].mapped + source_size, 0, (size_t)sizes[0] - source_size);
    memcpy(c->buffers[1].mapped, spans, spans_size);
    memcpy(c->buffers[2].mapped, weights, weights_size);
    c->UpdateDescriptorSets(c->device, 4, writes, 0, NULL);
    // Previous work has completed before any buffer is reused or replaced.
    if (c->ResetCommandPool(c->device, c->command_pool, 0) != VK_SUCCESS ||
        c->ResetFences(c->device, 1, &c->fence) != VK_SUCCESS) goto fail;
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    if (c->BeginCommandBuffer(c->command, &begin) != VK_SUCCESS) goto fail;
    c->CmdBindPipeline(c->command, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipeline);
    c->CmdBindDescriptorSets(c->command, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipeline_layout, 0, 1, &c->descriptor, 0, NULL);
    const uint32_t geometry[4] = { source_width, width, height, vertical };
    c->CmdPushConstants(c->command, c->pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof geometry, geometry);
    c->CmdDispatch(c->command, (width + 63) / 64, height, 1);
    VkMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
    c->CmdPipelineBarrier(c->command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
    if (c->EndCommandBuffer(c->command) != VK_SUCCESS) goto fail;
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c->command };
    if (c->QueueSubmit(c->queue, 1, &submit, c->fence) != VK_SUCCESS ||
        c->WaitForFences(c->device, 1, &c->fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS) goto fail;
    memcpy(output, c->buffers[3].mapped, (size_t)sizes[3]);
    return 1;
fail:
    // Do not dispatch again after a device/queue error. Zig uses SIMD instead.
    c->broken = 1;
    return 0;
}
