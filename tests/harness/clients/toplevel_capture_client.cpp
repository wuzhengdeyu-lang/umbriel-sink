#include "ext-foreign-toplevel-list-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>
#include <wayland-client.h>

namespace {
  struct Toplevel {
    ext_foreign_toplevel_handle_v1* handle = nullptr;
    std::string title;
    bool closed = false;
  };

  struct State {
    wl_display* display = nullptr;
    wl_registry* registry = nullptr;
    wl_shm* shm = nullptr;
    ext_foreign_toplevel_list_v1* list = nullptr;
    ext_foreign_toplevel_image_capture_source_manager_v1* sourceManager = nullptr;
    ext_image_copy_capture_manager_v1* captureManager = nullptr;
    ext_image_capture_source_v1* source = nullptr;
    ext_image_copy_capture_session_v1* session = nullptr;
    ext_image_copy_capture_frame_v1* frame = nullptr;
    wl_buffer* buffer = nullptr;
    void* pixels = MAP_FAILED;
    size_t size = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t format = UINT32_MAX;
    std::vector<uint32_t> shmFormats;
    std::vector<std::unique_ptr<Toplevel>> toplevels;
    bool constraintsDone = false;
    bool stopped = false;
    bool ready = false;
    bool failed = false;
    uint32_t failureReason = 0;
  };

  void handleClosed(void* data, ext_foreign_toplevel_handle_v1*) { static_cast<Toplevel*>(data)->closed = true; }
  void handleDone(void*, ext_foreign_toplevel_handle_v1*) {}
  void handleTitle(void* data, ext_foreign_toplevel_handle_v1*, const char* title) {
    static_cast<Toplevel*>(data)->title = title != nullptr ? title : "";
  }
  void handleAppId(void*, ext_foreign_toplevel_handle_v1*, const char*) {}
  void handleIdentifier(void*, ext_foreign_toplevel_handle_v1*, const char*) {}

  constexpr ext_foreign_toplevel_handle_v1_listener kHandleListener{
      .closed = handleClosed,
      .done = handleDone,
      .title = handleTitle,
      .app_id = handleAppId,
      .identifier = handleIdentifier,
  };

  void listToplevel(void* data, ext_foreign_toplevel_list_v1*, ext_foreign_toplevel_handle_v1* handle) {
    auto& state = *static_cast<State*>(data);
    auto toplevel = std::make_unique<Toplevel>();
    toplevel->handle = handle;
    ext_foreign_toplevel_handle_v1_add_listener(handle, &kHandleListener, toplevel.get());
    state.toplevels.push_back(std::move(toplevel));
  }
  void listFinished(void*, ext_foreign_toplevel_list_v1*) {}

  constexpr ext_foreign_toplevel_list_v1_listener kListListener{
      .toplevel = listToplevel,
      .finished = listFinished,
  };

  void sessionBufferSize(void* data, ext_image_copy_capture_session_v1*, uint32_t width, uint32_t height) {
    auto& state = *static_cast<State*>(data);
    state.width = width;
    state.height = height;
  }
  void sessionShmFormat(void* data, ext_image_copy_capture_session_v1*, uint32_t format) {
    static_cast<State*>(data)->shmFormats.push_back(format);
  }
  void sessionDmabufDevice(void*, ext_image_copy_capture_session_v1*, wl_array*) {}
  void sessionDmabufFormat(void*, ext_image_copy_capture_session_v1*, uint32_t, wl_array*) {}
  void sessionDone(void* data, ext_image_copy_capture_session_v1*) {
    static_cast<State*>(data)->constraintsDone = true;
  }
  void sessionStopped(void* data, ext_image_copy_capture_session_v1*) { static_cast<State*>(data)->stopped = true; }

  constexpr ext_image_copy_capture_session_v1_listener kSessionListener{
      .buffer_size = sessionBufferSize,
      .shm_format = sessionShmFormat,
      .dmabuf_device = sessionDmabufDevice,
      .dmabuf_format = sessionDmabufFormat,
      .done = sessionDone,
      .stopped = sessionStopped,
  };

  void frameTransform(void*, ext_image_copy_capture_frame_v1*, uint32_t) {}
  void frameDamage(void*, ext_image_copy_capture_frame_v1*, int32_t, int32_t, int32_t, int32_t) {}
  void framePresentationTime(void*, ext_image_copy_capture_frame_v1*, uint32_t, uint32_t, uint32_t) {}
  void frameReady(void* data, ext_image_copy_capture_frame_v1*) { static_cast<State*>(data)->ready = true; }
  void frameFailed(void* data, ext_image_copy_capture_frame_v1*, uint32_t reason) {
    auto& state = *static_cast<State*>(data);
    state.failed = true;
    state.failureReason = reason;
  }

  constexpr ext_image_copy_capture_frame_v1_listener kFrameListener{
      .transform = frameTransform,
      .damage = frameDamage,
      .presentation_time = framePresentationTime,
      .ready = frameReady,
      .failed = frameFailed,
  };

  void registryGlobal(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
    auto& state = *static_cast<State*>(data);
    const std::string_view iface = interface != nullptr ? interface : "";
    if (iface == wl_shm_interface.name) {
      state.shm = static_cast<wl_shm*>(wl_registry_bind(registry, name, &wl_shm_interface, std::min(version, 1U)));
    } else if (iface == ext_foreign_toplevel_list_v1_interface.name) {
      state.list = static_cast<ext_foreign_toplevel_list_v1*>(
          wl_registry_bind(registry, name, &ext_foreign_toplevel_list_v1_interface, std::min(version, 1U))
      );
      ext_foreign_toplevel_list_v1_add_listener(state.list, &kListListener, &state);
    } else if (iface == ext_foreign_toplevel_image_capture_source_manager_v1_interface.name) {
      state.sourceManager = static_cast<ext_foreign_toplevel_image_capture_source_manager_v1*>(wl_registry_bind(
          registry, name, &ext_foreign_toplevel_image_capture_source_manager_v1_interface, std::min(version, 1U)
      ));
    } else if (iface == ext_image_copy_capture_manager_v1_interface.name) {
      state.captureManager = static_cast<ext_image_copy_capture_manager_v1*>(
          wl_registry_bind(registry, name, &ext_image_copy_capture_manager_v1_interface, std::min(version, 1U))
      );
    }
  }
  void registryGlobalRemove(void*, wl_registry*, uint32_t) {}

  constexpr wl_registry_listener kRegistryListener{
      .global = registryGlobal,
      .global_remove = registryGlobalRemove,
  };

  bool dispatchUntil(State& state, const auto& predicate) {
    for (int i = 0; i < 200 && !predicate(); ++i) {
      if (wl_display_dispatch(state.display) < 0) {
        return false;
      }
    }
    return predicate();
  }

  bool createBuffer(State& state) {
    const auto supports = [&](uint32_t format) {
      return std::ranges::find(state.shmFormats, format) != state.shmFormats.end();
    };
    if (supports(WL_SHM_FORMAT_ARGB8888)) {
      state.format = WL_SHM_FORMAT_ARGB8888;
    } else if (supports(WL_SHM_FORMAT_XRGB8888)) {
      state.format = WL_SHM_FORMAT_XRGB8888;
    } else {
      return false;
    }

    const uint64_t stride = static_cast<uint64_t>(state.width) * 4;
    const uint64_t size = stride * state.height;
    if (state.width == 0 || state.height == 0 || size > static_cast<uint64_t>(INT32_MAX)) {
      return false;
    }
    state.size = static_cast<size_t>(size);
    const int fd = memfd_create("umbriel-toplevel-capture", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, static_cast<off_t>(state.size)) < 0) {
      if (fd >= 0) {
        close(fd);
      }
      return false;
    }
    state.pixels = mmap(nullptr, state.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (state.pixels == MAP_FAILED) {
      close(fd);
      return false;
    }
    std::ranges::fill(std::span(static_cast<uint32_t*>(state.pixels), state.size / 4), 0U);
    wl_shm_pool* pool = wl_shm_create_pool(state.shm, fd, static_cast<int>(state.size));
    state.buffer = wl_shm_pool_create_buffer(
        pool, 0, static_cast<int>(state.width), static_cast<int>(state.height), static_cast<int>(stride), state.format
    );
    wl_shm_pool_destroy(pool);
    close(fd);
    return state.buffer != nullptr;
  }

  void cleanup(State& state) {
    if (state.frame != nullptr) {
      ext_image_copy_capture_frame_v1_destroy(state.frame);
    }
    if (state.buffer != nullptr) {
      wl_buffer_destroy(state.buffer);
    }
    if (state.session != nullptr) {
      ext_image_copy_capture_session_v1_destroy(state.session);
    }
    if (state.source != nullptr) {
      ext_image_capture_source_v1_destroy(state.source);
    }
    if (state.captureManager != nullptr) {
      ext_image_copy_capture_manager_v1_destroy(state.captureManager);
    }
    if (state.sourceManager != nullptr) {
      ext_foreign_toplevel_image_capture_source_manager_v1_destroy(state.sourceManager);
    }
    if (state.pixels != MAP_FAILED) {
      munmap(state.pixels, state.size);
    }
    if (state.display != nullptr) {
      wl_display_disconnect(state.display);
    }
  }
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::println(stderr, "usage: toplevel-capture-client TITLE");
    return 2;
  }

  State state;
  state.display = wl_display_connect(nullptr);
  if (state.display == nullptr) {
    std::println(stderr, "toplevel-capture-client: cannot connect to WAYLAND_DISPLAY");
    return 2;
  }
  state.registry = wl_display_get_registry(state.display);
  wl_registry_add_listener(state.registry, &kRegistryListener, &state);
  bool ok = wl_display_roundtrip(state.display) >= 0 && wl_display_roundtrip(state.display) >= 0;
  if (!ok
      || state.shm == nullptr
      || state.list == nullptr
      || state.sourceManager == nullptr
      || state.captureManager == nullptr) {
    std::println(stderr, "toplevel-capture-client: required globals are unavailable");
    cleanup(state);
    return 2;
  }

  const std::string_view title = argv[1];
  const auto target = std::ranges::find_if(state.toplevels, [title](const auto& candidate) {
    return !candidate->closed && candidate->title == title;
  });
  if (target == state.toplevels.end()) {
    std::println(stderr, "toplevel-capture-client: toplevel '{}' was not advertised", title);
    cleanup(state);
    return 1;
  }

  state.source =
      ext_foreign_toplevel_image_capture_source_manager_v1_create_source(state.sourceManager, (*target)->handle);
  state.session = ext_image_copy_capture_manager_v1_create_session(state.captureManager, state.source, 0);
  ext_image_copy_capture_session_v1_add_listener(state.session, &kSessionListener, &state);
  ok = dispatchUntil(state, [&] { return state.constraintsDone || state.stopped; });
  if (!ok || state.stopped || !createBuffer(state)) {
    std::println(stderr, "toplevel-capture-client: no usable shared-memory capture constraints");
    cleanup(state);
    return 1;
  }

  state.frame = ext_image_copy_capture_session_v1_create_frame(state.session);
  ext_image_copy_capture_frame_v1_add_listener(state.frame, &kFrameListener, &state);
  ext_image_copy_capture_frame_v1_attach_buffer(state.frame, state.buffer);
  ext_image_copy_capture_frame_v1_damage_buffer(
      state.frame, 0, 0, static_cast<int32_t>(state.width), static_cast<int32_t>(state.height)
  );
  ext_image_copy_capture_frame_v1_capture(state.frame);
  ok = dispatchUntil(state, [&] { return state.ready || state.failed || state.stopped; });
  if (!ok || !state.ready) {
    std::println(stderr, "toplevel-capture-client: capture failed ({})", state.failureReason);
    cleanup(state);
    return 1;
  }

  const auto* pixels = static_cast<const uint32_t*>(state.pixels);
  const uint32_t x0 = state.width / 3;
  const uint32_t x1 = std::max(x0 + 1, state.width * 2 / 3);
  const uint32_t y0 = state.height / 3;
  const uint32_t y1 = std::max(y0 + 1, state.height * 2 / 3);
  uint64_t red = 0;
  uint64_t green = 0;
  uint64_t blue = 0;
  uint64_t alpha = 0;
  uint64_t count = 0;
  for (uint32_t y = y0; y < y1; ++y) {
    for (uint32_t x = x0; x < x1; ++x) {
      const uint32_t pixel = pixels[static_cast<size_t>(y) * state.width + x];
      red += (pixel >> 16U) & 0xFFU;
      green += (pixel >> 8U) & 0xFFU;
      blue += pixel & 0xFFU;
      alpha += state.format == WL_SHM_FORMAT_XRGB8888 ? 255U : (pixel >> 24U) & 0xFFU;
      ++count;
    }
  }
  std::println("{} {} {} {} {} {}", state.width, state.height, red / count, green / count, blue / count, alpha / count);
  cleanup(state);
  return 0;
}
