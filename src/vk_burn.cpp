// vk_burn.cpp — Vulkan compute GPU burn-in.
// Fills VRAM to a target percentage with buffers and dispatches a sustained
// FMA compute shader until a deadline. No ROCm or HIP needed.
//
// Usage: ./vk_burn <deadline_epoch> <vram_pct> [gpu_index]
//
// Build: g++ -O2 -o vk_burn vk_burn.cpp -lvulkan
// Shader: glslangValidator -V vk_burn.comp -o vk_burn.comp.spv

#include <vulkan/vulkan.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>
#include <string>
#include <fstream>

#define VK_CHECK(x) do { VkResult r = (x); if (r != VK_SUCCESS) { \
    fprintf(stderr, "Vulkan error %d at %s:%d\n", r, __FILE__, __LINE__); exit(1); } } while(0)

struct PushConstants {
    uint32_t buf_len;
    uint32_t iterations;
};

static std::vector<uint32_t> load_spirv(const char* path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    size_t sz = f.tellg();
    f.seekg(0);
    std::vector<uint32_t> code(sz / 4);
    f.read(reinterpret_cast<char*>(code.data()), sz);
    return code;
}

static std::string exe_dir() {
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return ".";
    buf[n] = 0;
    std::string s(buf);
    auto pos = s.rfind('/');
    return pos != std::string::npos ? s.substr(0, pos) : ".";
}

static std::string find_spv() {
    std::string dir = exe_dir();
    std::string candidates[] = {
        dir + "/vk_burn.comp.spv",
        dir + "/../src/vk_burn.comp.spv",
        "vk_burn.comp.spv",
        "src/vk_burn.comp.spv",
    };
    for (auto& p : candidates) {
        std::ifstream f(p);
        if (f.good()) return p;
    }
    fprintf(stderr, "cannot find vk_burn.comp.spv\n");
    exit(1);
}

static VkInstance create_instance() {
    VkApplicationInfo app_info{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app_info.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo inst_ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    inst_ci.pApplicationInfo = &app_info;
    VkInstance instance;
    VK_CHECK(vkCreateInstance(&inst_ci, nullptr, &instance));
    return instance;
}

int main(int argc, char** argv) {
    // --list mode: print "index\tdeviceName\tdeviceType" for all Vulkan devices
    if (argc >= 2 && std::string(argv[1]) == "--list") {
        VkInstance instance = create_instance();
        uint32_t dev_count = 0;
        vkEnumeratePhysicalDevices(instance, &dev_count, nullptr);
        std::vector<VkPhysicalDevice> devs(dev_count);
        vkEnumeratePhysicalDevices(instance, &dev_count, devs.data());
        for (uint32_t i = 0; i < dev_count; i++) {
            VkPhysicalDeviceProperties props;
            vkGetPhysicalDeviceProperties(devs[i], &props);
            // deviceType: 1=integrated, 2=discrete, 3=virtual, 4=cpu
            printf("%u\t%s\t%u\n", i, props.deviceName, props.deviceType);
        }
        return 0;
    }

    if (argc < 3) {
        fprintf(stderr, "usage: %s <deadline_epoch> <vram_pct> [gpu_index]\n", argv[0]);
        fprintf(stderr, "       %s --list\n", argv[0]);
        return 1;
    }
    time_t deadline = (time_t)atoll(argv[1]);
    int vram_pct = atoi(argv[2]);
    int gpu_idx = argc > 3 ? atoi(argv[3]) : 0;

    // --- Instance ---
    VkInstance instance = create_instance();

    // --- Pick physical device ---
    uint32_t dev_count = 0;
    vkEnumeratePhysicalDevices(instance, &dev_count, nullptr);
    if (dev_count == 0) { fprintf(stderr, "no Vulkan devices\n"); return 1; }
    std::vector<VkPhysicalDevice> devs(dev_count);
    vkEnumeratePhysicalDevices(instance, &dev_count, devs.data());
    if (gpu_idx >= (int)dev_count) {
        fprintf(stderr, "gpu_index %d out of range (have %u)\n", gpu_idx, dev_count);
        return 1;
    }
    VkPhysicalDevice phys = devs[gpu_idx];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(phys, &props);
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);

    // Find device-local memory heap size
    VkDeviceSize heap_size = 0;
    uint32_t mem_type_idx = UINT32_MAX;
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        auto flags = mem_props.memoryTypes[i].propertyFlags;
        if (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
            uint32_t hi = mem_props.memoryTypes[i].heapIndex;
            if (mem_props.memoryHeaps[hi].size > heap_size) {
                heap_size = mem_props.memoryHeaps[hi].size;
                mem_type_idx = i;
            }
        }
    }
    VkDeviceSize target = heap_size * vram_pct / 100;
    fprintf(stderr, "gpu%d: %s  heap=%.0fMB target=%.0fMB(%d%%)\n",
            gpu_idx, props.deviceName,
            heap_size / 1048576.0, target / 1048576.0, vram_pct);

    // --- Find compute queue family ---
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qf_count, nullptr);
    std::vector<VkQueueFamilyProperties> qf_props(qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qf_count, qf_props.data());
    uint32_t compute_qf = UINT32_MAX;
    for (uint32_t i = 0; i < qf_count; i++) {
        if (qf_props[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { compute_qf = i; break; }
    }
    if (compute_qf == UINT32_MAX) { fprintf(stderr, "no compute queue\n"); return 1; }

    // --- Create logical device ---
    float prio = 1.0f;
    VkDeviceQueueCreateInfo q_ci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    q_ci.queueFamilyIndex = compute_qf;
    q_ci.queueCount = 1;
    q_ci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dev_ci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dev_ci.queueCreateInfoCount = 1;
    dev_ci.pQueueCreateInfos = &q_ci;
    VkDevice device;
    VK_CHECK(vkCreateDevice(phys, &dev_ci, nullptr, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, compute_qf, 0, &queue);

    // --- Allocate VRAM buffers to fill target ---
    const VkDeviceSize CHUNK = 256 * 1024 * 1024; // 256MB per buffer
    VkDeviceSize allocated = 0;
    struct BufAlloc { VkBuffer buf; VkDeviceMemory mem; VkDeviceSize size; };
    std::vector<BufAlloc> allocs;

    while (allocated < target) {
        VkDeviceSize sz = std::min(CHUNK, target - allocated);
        VkBufferCreateInfo buf_ci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        buf_ci.size = sz;
        buf_ci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        VkBuffer buf;
        if (vkCreateBuffer(device, &buf_ci, nullptr, &buf) != VK_SUCCESS) break;

        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(device, buf, &req);
        VkMemoryAllocateInfo alloc_ci{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        alloc_ci.allocationSize = req.size;
        alloc_ci.memoryTypeIndex = mem_type_idx;
        VkDeviceMemory mem;
        if (vkAllocateMemory(device, &alloc_ci, nullptr, &mem) != VK_SUCCESS) {
            vkDestroyBuffer(device, buf, nullptr);
            break;
        }
        vkBindBufferMemory(device, buf, mem, 0);
        allocs.push_back({buf, mem, sz});
        allocated += sz;
    }
    fprintf(stderr, "gpu%d: allocated %.0fMB in %zu buffers\n",
            gpu_idx, allocated / 1048576.0, allocs.size());
    if (allocs.empty()) { fprintf(stderr, "no memory allocated\n"); return 1; }

    // --- Load shader ---
    auto spv_path = find_spv();
    auto spirv = load_spirv(spv_path.c_str());
    VkShaderModuleCreateInfo sm_ci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    sm_ci.codeSize = spirv.size() * 4;
    sm_ci.pCode = spirv.data();
    VkShaderModule shader;
    VK_CHECK(vkCreateShaderModule(device, &sm_ci, nullptr, &shader));

    // --- Descriptor set layout ---
    VkDescriptorSetLayoutBinding binding{};
    binding.binding = 0;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayoutCreateInfo dsl_ci{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    dsl_ci.bindingCount = 1;
    dsl_ci.pBindings = &binding;
    VkDescriptorSetLayout dsl;
    VK_CHECK(vkCreateDescriptorSetLayout(device, &dsl_ci, nullptr, &dsl));

    // --- Push constant range ---
    VkPushConstantRange pc_range{};
    pc_range.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    pc_range.offset = 0;
    pc_range.size = sizeof(PushConstants);

    // --- Pipeline layout ---
    VkPipelineLayoutCreateInfo pl_ci{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pl_ci.setLayoutCount = 1;
    pl_ci.pSetLayouts = &dsl;
    pl_ci.pushConstantRangeCount = 1;
    pl_ci.pPushConstantRanges = &pc_range;
    VkPipelineLayout pipeline_layout;
    VK_CHECK(vkCreatePipelineLayout(device, &pl_ci, nullptr, &pipeline_layout));

    // --- Compute pipeline ---
    VkComputePipelineCreateInfo cp_ci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    cp_ci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cp_ci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cp_ci.stage.module = shader;
    cp_ci.stage.pName = "main";
    cp_ci.layout = pipeline_layout;
    VkPipeline pipeline;
    VK_CHECK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cp_ci, nullptr, &pipeline));

    // --- Descriptor pool + set ---
    VkDescriptorPoolSize pool_sz{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
    VkDescriptorPoolCreateInfo dp_ci{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dp_ci.maxSets = 1;
    dp_ci.poolSizeCount = 1;
    dp_ci.pPoolSizes = &pool_sz;
    VkDescriptorPool desc_pool;
    VK_CHECK(vkCreateDescriptorPool(device, &dp_ci, nullptr, &desc_pool));

    VkDescriptorSetAllocateInfo ds_ai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    ds_ai.descriptorPool = desc_pool;
    ds_ai.descriptorSetCount = 1;
    ds_ai.pSetLayouts = &dsl;
    VkDescriptorSet desc_set;
    VK_CHECK(vkAllocateDescriptorSets(device, &ds_ai, &desc_set));

    // --- Command buffer ---
    VkCommandPoolCreateInfo cmd_pool_ci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cmd_pool_ci.queueFamilyIndex = compute_qf;
    cmd_pool_ci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool cmd_pool;
    VK_CHECK(vkCreateCommandPool(device, &cmd_pool_ci, nullptr, &cmd_pool));

    VkCommandBufferAllocateInfo cmd_ai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cmd_ai.commandPool = cmd_pool;
    cmd_ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmd_ai.commandBufferCount = 1;
    VkCommandBuffer cmd;
    VK_CHECK(vkAllocateCommandBuffers(device, &cmd_ai, &cmd));

    VkFenceCreateInfo fence_ci{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    VK_CHECK(vkCreateFence(device, &fence_ci, nullptr, &fence));

    // --- Main burn loop ---
    fprintf(stderr, "gpu%d: burning until deadline %lld ...\n", gpu_idx, (long long)deadline);
    uint64_t dispatches = 0;

    while (time(nullptr) < deadline) {
        // Cycle through allocated buffers to keep all VRAM hot
        for (auto& a : allocs) {
            if (time(nullptr) >= deadline) break;

            uint32_t elem_count = (uint32_t)(a.size / sizeof(float));

            // Update descriptor to point to this buffer
            VkDescriptorBufferInfo buf_info{a.buf, 0, a.size};
            VkWriteDescriptorSet wr{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
            wr.dstSet = desc_set;
            wr.dstBinding = 0;
            wr.descriptorCount = 1;
            wr.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            wr.pBufferInfo = &buf_info;
            vkUpdateDescriptorSets(device, 1, &wr, 0, nullptr);

            PushConstants pc{elem_count, 512};

            VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
            begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkResetCommandBuffer(cmd, 0);
            vkBeginCommandBuffer(cmd, &begin);
            vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE,
                                    pipeline_layout, 0, 1, &desc_set, 0, nullptr);
            vkCmdPushConstants(cmd, pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT,
                               0, sizeof(pc), &pc);
            uint32_t groups = (elem_count + 255) / 256;
            vkCmdDispatch(cmd, groups, 1, 1);
            vkEndCommandBuffer(cmd);

            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &cmd;
            vkResetFences(device, 1, &fence);
            vkQueueSubmit(queue, 1, &submit, fence);
            vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
            dispatches++;
        }
    }

    fprintf(stderr, "gpu%d: done bdf=N/A dispatches=%llu allocated=%.0fMB\n",
            gpu_idx, (unsigned long long)dispatches, allocated / 1048576.0);

    // Cleanup
    vkDestroyFence(device, fence, nullptr);
    vkDestroyCommandPool(device, cmd_pool, nullptr);
    vkDestroyDescriptorPool(device, desc_pool, nullptr);
    vkDestroyPipeline(device, pipeline, nullptr);
    vkDestroyPipelineLayout(device, pipeline_layout, nullptr);
    vkDestroyDescriptorSetLayout(device, dsl, nullptr);
    vkDestroyShaderModule(device, shader, nullptr);
    for (auto& a : allocs) {
        vkDestroyBuffer(device, a.buf, nullptr);
        vkFreeMemory(device, a.mem, nullptr);
    }
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);
    return 0;
}
