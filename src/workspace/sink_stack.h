#pragma once

#include <algorithm>
#include <cstddef>
#include <optional>
#include <vector>

namespace umbriel {

  // Pure LIFO membership used by Workspace. The back of the vector is depth 0.
  // Keeping this container independent of View makes ordering and arbitrary
  // lifecycle removal testable without a compositor.
  template <typename T> class SinkStack {
  public:
    [[nodiscard]] bool push(T* entry) {
      if (entry == nullptr || contains(entry)) {
        return false;
      }
      m_entries.push_back(entry);
      return true;
    }

    [[nodiscard]] T* pop() {
      if (m_entries.empty()) {
        return nullptr;
      }
      T* entry = m_entries.back();
      m_entries.pop_back();
      return entry;
    }

    [[nodiscard]] bool remove(const T* entry) {
      const auto found = std::ranges::find(m_entries, entry);
      if (found == m_entries.end()) {
        return false;
      }
      m_entries.erase(found);
      return true;
    }

    [[nodiscard]] bool contains(const T* entry) const { return std::ranges::find(m_entries, entry) != m_entries.end(); }

    [[nodiscard]] std::optional<size_t> depth(const T* entry) const {
      const auto found = std::ranges::find(m_entries, entry);
      if (found == m_entries.end()) {
        return std::nullopt;
      }
      return static_cast<size_t>(std::distance(found, m_entries.end()) - 1);
    }

    [[nodiscard]] bool empty() const { return m_entries.empty(); }
    [[nodiscard]] size_t size() const { return m_entries.size(); }
    [[nodiscard]] const std::vector<T*>& entries() const { return m_entries; }

  private:
    std::vector<T*> m_entries;
  };

} // namespace umbriel
