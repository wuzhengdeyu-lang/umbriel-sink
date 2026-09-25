#pragma once

#include "core/animation.h"

#include <array>
#include <cstddef>
#include <functional>
#include <memory>
#include <vector>
#include <wayland-server-core.h>

extern "C" {
#include <wlr/util/box.h>
}

struct wlr_scene_border;
struct wlr_scene_buffer;
struct wlr_scene_node;
struct wlr_scene_tree;
struct wlr_surface;

namespace umbriel {

  struct BorderSnapshot;
  class Server;
  class SurfaceBlur;
  class SurfaceShadow;
  class View;

  // A passive, non-interactive presentation of every committed surface owned by
  // a View. It never owns the View or its wl_surfaces. The projection listens to
  // surface lifetime and commit events and mirrors the protocol buffer state,
  // explicit sync, colour metadata and frame pacing into an independent scene
  // subtree. Overview cards and Sink entries use the same implementation.
  class WindowProjection {
  public:
    using ChangedCallback = std::function<void()>;

    WindowProjection(
        Server& server, View& view, wlr_scene_tree* parent, ChangedCallback changed = {},
        bool mirrorAnimationShaders = false
    );
    ~WindowProjection();

    WindowProjection(const WindowProjection&) = delete;
    WindowProjection& operator=(const WindowProjection&) = delete;

    void syncSurfaces();
    void setBox(const wlr_box& box);
    void setOpacity(float opacity);
    void setBorderColor(const std::array<float, 4>& color);
    void setEnabled(bool enabled);
    void setDepth(float depth);
    void setSelfBlurEnabled(bool enabled);
    void animateTo(const wlr_box& box, float opacity, int durationMs, const AnimationCurve& curve);
    bool tick(uint64_t nowMsec);

    [[nodiscard]] bool animating() const;
    [[nodiscard]] bool enabled() const { return m_enabled; }
    [[nodiscard]] float depth() const { return m_depth; }
    [[nodiscard]] const wlr_box& box() const { return m_box; }
    [[nodiscard]] wlr_scene_tree* tree() const { return m_tree; }
    [[nodiscard]] wlr_scene_node* borderNode() const;
    [[nodiscard]] size_t surfaceCount() const { return m_surfaces.size(); }

    // Copy the currently presented buffers and border into `target`. Coordinates
    // are target-local and start at the supplied offset. Used by Overview's
    // close snapshot so extracting the mirror does not regress its lifecycle.
    int snapshot(wlr_scene_tree* target, int offsetX, int offsetY, std::vector<BorderSnapshot>& borders) const;

  private:
    struct ProjectedSurface {
      WindowProjection* projection = nullptr;
      wlr_surface* surface = nullptr;
      wlr_scene_buffer* sourceBuffer = nullptr;
      wlr_scene_buffer* buffer = nullptr;
      int sx = 0;
      int sy = 0;
      bool root = false;
      bool popup = false;
      bool seen = false;
      wl_listener commit{};
      wl_listener destroy{};
      wl_listener outputSample{};
      wl_listener frameDone{};
    };

    struct EnumerateContext {
      WindowProjection* projection = nullptr;
      bool popup = false;
    };

    static void enumerateSurface(wlr_surface* surface, int sx, int sy, void* data);
    static void onSurfaceCommit(wl_listener* listener, void* data);
    static void onSurfaceDestroy(wl_listener* listener, void* data);
    static void onBufferOutputSample(wl_listener* listener, void* data);
    static void onBufferFrameDone(wl_listener* listener, void* data);

    void addOrSyncSurface(wlr_surface* surface, int sx, int sy, bool popup);
    void syncBuffer(ProjectedSurface& entry);
    void destroySurface(ProjectedSurface* entry);
    void applyGeometry();
    void applyOpacity();
    void applySelfBlur();
    void scheduleFrame() const;

    Server* m_server = nullptr;
    View* m_view = nullptr;
    wlr_scene_tree* m_tree = nullptr;
    wlr_scene_tree* m_effectTree = nullptr;
    wlr_scene_border* m_border = nullptr;
    std::unique_ptr<SurfaceBlur> m_blur;
    std::unique_ptr<SurfaceShadow> m_shadow;
    std::vector<std::unique_ptr<ProjectedSurface>> m_surfaces;
    ChangedCallback m_changed;
    std::array<float, 4> m_borderColor{};
    wlr_box m_box{};
    AnimatedValue m_x;
    AnimatedValue m_y;
    AnimatedValue m_width;
    AnimatedValue m_height;
    AnimatedValue m_opacity{1.0};
    float m_depth = 0.0F;
    bool m_enabled = false;
    bool m_selfBlurEnabled = false;
    bool m_mirrorAnimationShaders = false;
  };

} // namespace umbriel
