package main
import "core:fmt"
import "core:log"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"
import "core:mem"
import "core:strings"
import "core:runtime"
import "core:math"

VALIDATION :: #config(VALIDATION, false)

WINDOW_WIDTH  :: 600
WINDOW_HEIGHT :: 400
WINDOW_TITLE  :: "Vulkan"

REQUIRED_VULKAN_LAYERS     :: []cstring{"VK_LAYER_KHRONOS_validation"}
REQUIRED_DEVICE_EXTENSIONS :: []cstring {vk.KHR_SWAPCHAIN_EXTENSION_NAME}

Debug_Context :: struct {
    logger: log.Logger,
}

Application :: struct {
    vk_instance:         vk.Instance,
    vk_debug_messenger:  vk.DebugUtilsMessengerEXT,
    vk_physical_device:  vk.PhysicalDevice,
    vk_logical_device:   vk.Device,
    vk_graphics_queue:   vk.Queue,
    vk_present_queue:    vk.Queue,
    vk_surface:          vk.SurfaceKHR,
    vk_swapchain:        vk.SwapchainKHR,
    vk_swapchain_images: []vk.Image,
    vk_image_views:      [dynamic]vk.ImageView,
    vk_swapchain_format: vk.Format,
    vk_swapchain_extent: vk.Extent2D,
    window:              glfw.WindowHandle,
    debug_context:       ^Debug_Context,
}

make_app :: proc() -> (app: Application) {
    log.info("Initializing application")
	if glfw.Init() != 1 {
        description, code := glfw.GetError()
        log.errorf("Failed to initialize GLFW:\n\tDescription: %s\n\tCode: %d", description, code)
        return
    }
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    glfw.WindowHint(glfw.RESIZABLE, 0)
    vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))

    app = {}
    app.debug_context = new(Debug_Context)
    app.debug_context.logger = context.logger
	app.window = glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
    app.vk_instance = initialize_vulkan(app.debug_context)
    when VALIDATION {
        app.vk_debug_messenger = setup_debug_callback(app.vk_instance, app.debug_context)
    }

    app.vk_surface = create_surface(&app)
    app.vk_physical_device = pick_physical_device(&app)
    app.vk_logical_device = create_logical_device(&app)
    app.vk_swapchain, app.vk_swapchain_images, app.vk_swapchain_format, app.vk_swapchain_extent = create_swap_chain(&app)
    app.vk_image_views = create_image_views(app.vk_swapchain_images, app.vk_swapchain_format, app.vk_logical_device)

    return
}

app_destroy :: proc(app: ^Application) {
    log.info("Destroying application")
    when VALIDATION {
        destroy_debug_messenger(app.vk_instance, app.vk_debug_messenger)
    }

    for view in app.vk_image_views {
        vk.DestroyImageView(app.vk_logical_device, view, nil)
    }
    delete(app.vk_image_views)

    vk.DestroySwapchainKHR(app.vk_logical_device, app.vk_swapchain, nil)
    vk.DestroyDevice(app.vk_logical_device, nil)
    vk.DestroySurfaceKHR(app.vk_instance, app.vk_surface, nil)
    vk.DestroyInstance(app.vk_instance, nil)

    log.info("Destroying window")
    glfw.DestroyWindow(app.window)
    log.info("Terminating glfw")
    glfw.Terminate()
    free(app.debug_context)
    delete(app.vk_swapchain_images)
}

main :: proc() {
    context.logger = log.create_console_logger()

    app := make_app()
    defer app_destroy(&app)

	for !glfw.WindowShouldClose(app.window) {
		glfw.PollEvents()
	}
}

initialize_vulkan :: proc(dbg: ^Debug_Context) -> (instance: vk.Instance) {
    when VALIDATION {
        if !check_validation_layers() {
            return
        }
    }

    info := vk.ApplicationInfo {
        sType              = vk.StructureType.APPLICATION_INFO,
        pApplicationName   = "Hello Triangle",
        applicationVersion = vk.MAKE_VERSION(1, 0, 0),
        pEngineName        = "No Engine",
        engineVersion      = vk.MAKE_VERSION(1, 0, 0),
        apiVersion         = vk.API_VERSION_1_3,
    }

    extensions := get_required_extensions()
    defer delete(extensions)

    instance_info := vk.InstanceCreateInfo {
        sType                   = vk.StructureType.INSTANCE_CREATE_INFO,
        pApplicationInfo        = &info,
        enabledExtensionCount   = cast(u32)len(extensions),
        ppEnabledExtensionNames = raw_data(extensions),
        enabledLayerCount       = 0,
    }

    when VALIDATION {
        layers := REQUIRED_VULKAN_LAYERS
        dbg_info := create_debug_info_struct(dbg)
        instance_info.enabledLayerCount = cast(u32)len(layers)
        instance_info.ppEnabledLayerNames = raw_data(layers)
        instance_info.pNext = cast(^vk.DebugUtilsMessengerCreateInfoEXT)(&dbg_info)
    }

    log.debug("Creating Vulkan instance")
    result := vk.CreateInstance(&instance_info, nil, &instance)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create Vulkan instance")
    }
    vk.load_proc_addresses_instance(instance)

    return
}

check_validation_layers :: proc() -> bool {
    log.info("Performing validation layer check")
    count: u32
    vk.EnumerateInstanceLayerProperties(&count, nil)

    properties := make([]vk.LayerProperties, count)
    defer delete(properties)
    vk.EnumerateInstanceLayerProperties(&count, raw_data(properties))

    req: for required_layer in REQUIRED_VULKAN_LAYERS {
        found := false
        for &property in properties {
            if required_layer == cstring(raw_data(&property.layerName)) {
                found = true
            }
        }
        if !found {
            log.errorf("Required validation layer '%s' not found!", required_layer)
            return false
        }else {
            log.debug("Found required validation layer: ", required_layer)
            break req
        }
    }

    return true
}

// @Allocates
get_required_extensions :: proc() -> []cstring {
    extensions := make([dynamic]cstring)
    glfw_extensions := glfw.GetRequiredInstanceExtensions()
    for ext in glfw_extensions {
        append(&extensions, ext)
    }

    append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

    return extensions[:]
}

create_debug_info_struct :: proc(dbg: ^Debug_Context) -> vk.DebugUtilsMessengerCreateInfoEXT {
    return vk.DebugUtilsMessengerCreateInfoEXT {
        sType           = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = {.ERROR, .VERBOSE, .WARNING},
        messageType     = {.DEVICE_ADDRESS_BINDING, .GENERAL, .PERFORMANCE, .VALIDATION},
        pfnUserCallback = debug_callback,
        pUserData       = dbg,
    }
}

setup_debug_callback :: proc(instance: vk.Instance, dbg: ^Debug_Context) -> (debug_messenger: vk.DebugUtilsMessengerEXT) {
    info := create_debug_info_struct(dbg)

    func := cast(vk.ProcCreateDebugUtilsMessengerEXT)vk.GetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT")
    if func != nil {
        result := func(instance, &info, nil, &debug_messenger)
        if result != vk.Result.SUCCESS {
            log.errorf("Failed to create debug messenger: %v", result)
        }
    } else {
        log.error("Could not find proc 'vkDestroyDebugUtilsMessengerEXT'")
    }
    return
}

destroy_debug_messenger :: proc(instance: vk.Instance, messenger: vk.DebugUtilsMessengerEXT) {
    func := cast(vk.ProcDestroyDebugUtilsMessengerEXT)vk.GetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")
    if func != nil {
        func(instance, messenger, nil)
    } else {
        log.error("Could not find proc 'vkDestroyDebugUtilsMessengerEXT'")
    }
}

debug_callback :: proc "system" (messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
    dbg := cast(^Debug_Context)pUserData
    context = runtime.default_context()
    context.logger = dbg.logger

    // log.error(pCallbackData.pMessage)
    switch(messageSeverity) {
        case {.ERROR}:
            log.error(pCallbackData.pMessage)
        case {.VERBOSE}:
            // log.debug(pCallbackData.pMessage)
        case {.INFO}:
            log.info(pCallbackData.pMessage)
        case {.WARNING}:
            log.warn(pCallbackData.pMessage)
    }
    return false
}

pick_physical_device :: proc(app: ^Application) -> (device: vk.PhysicalDevice) {
    count: u32
    vk.EnumeratePhysicalDevices(app.vk_instance, &count, nil)

    devices := make([]vk.PhysicalDevice, count)
    defer delete(devices)

    vk.EnumeratePhysicalDevices(app.vk_instance, &count, raw_data(devices))

    for device in devices {
        if is_device_suitable(device, app.vk_surface) {
            return device
        }
    }
    log.error("Failed to find a suitable GPU")
    return nil
}

is_device_suitable :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR)  -> bool {
    indices := get_queue_families(device, surface)
    extensions_supported := check_device_extension_support(device)

    swapchain_good := false
    if extensions_supported {
        details := query_swapchain_support(device, surface)
        defer delete_swap_chain_support_details(&details)
        log.debug(len(details.formats))
        swapchain_good = len(details.formats) > 0 && len(details.present_modes) > 0
    }

    return is_queue_family_complete(indices) && extensions_supported && swapchain_good
}

QueueFamilyIndices :: struct {
    graphics_family: Maybe(int),
    present_family: Maybe(int),
}

is_queue_family_complete :: proc(using family: QueueFamilyIndices) -> bool {
    _, ok := family.graphics_family.?
    _, ok2 := family.present_family.?
    return ok && ok2
}

get_unique_queue_families :: proc(using indices: QueueFamilyIndices) -> [2]u32 { 
    return [?]u32{cast(u32)graphics_family.(int), cast(u32)present_family.(int)}
}

get_queue_families :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (indices: QueueFamilyIndices) {
    count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

    properties := make([]vk.QueueFamilyProperties, count)
    defer delete(properties)

    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(properties))

    for property, i in properties {
        if vk.QueueFlag.GRAPHICS in property.queueFlags {
            indices.graphics_family = i
        }

        present_support: b32
        vk.GetPhysicalDeviceSurfaceSupportKHR(device, cast(u32)i, surface, &present_support)
        if present_support {
            indices.present_family = i
        }
    }
    return
}

create_logical_device :: proc(app: ^Application) -> (logical_device: vk.Device){
    indices := get_queue_families(app.vk_physical_device, app.vk_surface)

    fields := reflect.struct_fields_zipped(typeid_of(QueueFamilyIndices))

    unique_families := get_unique_queue_families(indices)
    queue_info := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(unique_families))
    defer delete(queue_info)

    for fam in unique_families {
        queue_priority := []f32{1.0}
        append(&queue_info, vk.DeviceQueueCreateInfo{
            sType            = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = fam,
            queueCount       = 1,
            pQueuePriorities = raw_data(queue_priority),
        })
    }
    log.debug(queue_info)

    device_features := []vk.PhysicalDeviceFeatures{}

    create_info := vk.DeviceCreateInfo {
        sType                   = vk.StructureType.DEVICE_CREATE_INFO,
        pQueueCreateInfos       = raw_data(queue_info),
        queueCreateInfoCount    = cast(u32)len(queue_info),
        pEnabledFeatures        = raw_data(device_features),
        ppEnabledExtensionNames = raw_data(REQUIRED_DEVICE_EXTENSIONS),
        enabledExtensionCount   = cast(u32)len(REQUIRED_DEVICE_EXTENSIONS),
    }

    result := vk.CreateDevice(app.vk_physical_device, &create_info, nil, &logical_device)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create logical device")
        return
    }

    vk.GetDeviceQueue(logical_device, cast(u32)indices.graphics_family.(int), 0, &app.vk_graphics_queue)
    vk.GetDeviceQueue(logical_device, cast(u32)indices.present_family.(int), 0, &app.vk_present_queue)
    return
}

create_surface :: proc(app: ^Application) -> (surface: vk.SurfaceKHR) {
    result := glfw.CreateWindowSurface(app.vk_instance, app.window, nil, &surface)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create window surface")
    }
    return
}

check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
    count: u32
    vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)

    properties := make([]vk.ExtensionProperties, count)
    defer delete(properties)
    vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(properties))

    req: for required_device_extension in REQUIRED_DEVICE_EXTENSIONS {
        found := false
        for &property in properties {
            if required_device_extension == cstring(raw_data(&property.extensionName)) {
                found = true
            }
        }
        if !found {
            log.errorf("Required validation layer '%s' not found!", required_device_extension)
            return false
        }else {
            log.debug("Found required validation layer: ", required_device_extension)
            break req
        }
    }

    return true
}

Swap_Chain_Support_Details :: struct {
    capabilities:  vk.SurfaceCapabilitiesKHR,
    formats:       []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
}

delete_swap_chain_support_details :: proc(using details: ^Swap_Chain_Support_Details) {
    delete(formats)
    delete(present_modes)
}

query_swapchain_support :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (details: Swap_Chain_Support_Details) {
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities)

    format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, nil)

    if format_count != 0 {
        details.formats = make([]vk.SurfaceFormatKHR, format_count)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, raw_data(details.formats))
    }

    present_mode_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, nil)
    if present_mode_count != 0 {
        details.present_modes = make([]vk.PresentModeKHR, present_mode_count)
        vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, raw_data(details.present_modes))
    }
    return
}

choose_swap_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
    for format in formats {
        if format.format == vk.Format.B8G8R8A8_SRGB && format.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
            return format
        }
    }
    log.warn("Could not find ideal format and colorspace for swap surface")
    return formats[0];
}

choose_swap_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
    for mode in modes {
        if mode == vk.PresentModeKHR.MAILBOX {
            return mode
        }
    }
    return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(app: ^Application, capabilities: vk.SurfaceCapabilitiesKHR) -> (extent: vk.Extent2D) {
    if capabilities.currentExtent.width != max(u32) {
        return capabilities.currentExtent
    } else {
        width, height := glfw.GetFramebufferSize(app.window)
        extent.width = clamp(cast(u32)width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
        extent.height = clamp(cast(u32)height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)
    }
    return
}

create_swap_chain :: proc(app: ^Application) -> (swapchain: vk.SwapchainKHR, images: []vk.Image, format: vk.Format, extent: vk.Extent2D) {
    details := query_swapchain_support(app.vk_physical_device, app.vk_surface)
    defer delete_swap_chain_support_details(&details)

    present_mode := choose_swap_present_mode(details.present_modes)
    surface_format := choose_swap_surface_format(details.formats)
    format = surface_format.format
    extent = choose_swap_extent(app, details.capabilities)


    image_count := details.capabilities.minImageCount + 1
    if details.capabilities.maxImageCount > 0 && image_count > details.capabilities.maxImageCount {
        image_count = details.capabilities.maxImageCount
    }

    create_info := vk.SwapchainCreateInfoKHR {
        sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        surface = app.vk_surface,
        minImageCount = image_count,
        imageFormat = format,
        imageColorSpace = surface_format.colorSpace,
        presentMode = present_mode,
        imageExtent = extent,
        imageArrayLayers = 1,
        imageUsage = {vk.ImageUsageFlag.COLOR_ATTACHMENT},

        imageSharingMode = vk.SharingMode.EXCLUSIVE,
        preTransform = details.capabilities.currentTransform,
        compositeAlpha = {vk.CompositeAlphaFlagKHR.OPAQUE},
        clipped = true,
        oldSwapchain = 0,
    }

    result := vk.CreateSwapchainKHR(app.vk_logical_device, &create_info, nil, &swapchain)
    if result != vk.Result.SUCCESS {
        log.error("Failed to created swapchain")
    }

    swapchain_image_count: u32
    vk.GetSwapchainImagesKHR(app.vk_logical_device, swapchain, &swapchain_image_count, nil)

    images = make([]vk.Image, swapchain_image_count)

    vk.GetSwapchainImagesKHR(app.vk_logical_device, swapchain, &swapchain_image_count, raw_data(images))
    return
}

create_image_views :: proc(images: []vk.Image, format: vk.Format, device: vk.Device) -> [dynamic]vk.ImageView {
    views := make([dynamic]vk.ImageView, 0, len(images))

    for image in images {
        create_info := vk.ImageViewCreateInfo {
            sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
            format = format,
            image = image,
            viewType = vk.ImageViewType.D2,
            components = vk.ComponentMapping {
                r = vk.ComponentSwizzle.IDENTITY,
                g = vk.ComponentSwizzle.IDENTITY,
                b = vk.ComponentSwizzle.IDENTITY,
                a = vk.ComponentSwizzle.IDENTITY,
            },
            subresourceRange = vk.ImageSubresourceRange {
                aspectMask = {vk.ImageAspectFlag.COLOR},
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1,
            }
        }

        view: vk.ImageView
        vk.CreateImageView(device, &create_info, nil, &view)

        append(&views, view)
    }
    return views
}