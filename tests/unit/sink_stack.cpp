#include "workspace/sink_stack.h"

#include "check.h"

namespace {

  struct Entry {};

} // namespace

UMBRIEL_TEST(pushPopIsStrictLifoAndRejectsDuplicates) {
  umbriel::SinkStack<Entry> stack;
  Entry a;
  Entry b;
  Entry c;

  CHECK(!stack.push(nullptr));
  CHECK(stack.push(&a));
  CHECK(stack.push(&b));
  CHECK(stack.push(&c));
  CHECK(!stack.push(&b));
  CHECK_EQ(stack.size(), 3U);
  CHECK_EQ(stack.depth(&c), std::optional<size_t>(0));
  CHECK_EQ(stack.depth(&b), std::optional<size_t>(1));
  CHECK_EQ(stack.depth(&a), std::optional<size_t>(2));

  CHECK(stack.pop() == &c);
  CHECK(stack.pop() == &b);
  CHECK(stack.pop() == &a);
  CHECK(stack.pop() == nullptr);
}

UMBRIEL_TEST(arbitraryRemovalPreservesSurvivorOrderAndDepth) {
  umbriel::SinkStack<Entry> stack;
  Entry a;
  Entry b;
  Entry c;
  Entry missing;

  CHECK(stack.push(&a));
  CHECK(stack.push(&b));
  CHECK(stack.push(&c));
  CHECK(stack.remove(&b));
  CHECK(!stack.remove(&missing));
  CHECK(!stack.depth(&b).has_value());
  CHECK_EQ(stack.depth(&c), std::optional<size_t>(0));
  CHECK_EQ(stack.depth(&a), std::optional<size_t>(1));
  CHECK(stack.pop() == &c);
  CHECK(stack.pop() == &a);
}

UMBRIEL_TEST(workspaceTransferAppendsSourceWithoutReversingEitherStack) {
  umbriel::SinkStack<Entry> target;
  umbriel::SinkStack<Entry> source;
  Entry targetOld;
  Entry targetNew;
  Entry sourceOld;
  Entry sourceMiddle;
  Entry sourceNew;

  CHECK(target.push(&targetOld));
  CHECK(target.push(&targetNew));
  CHECK(source.push(&sourceOld));
  CHECK(source.push(&sourceMiddle));
  CHECK(source.push(&sourceNew));

  // Workspace migration iterates entries bottom-to-top and pushes them onto
  // the destination. Its existing stack remains below the transferred one.
  for (Entry* entry : source.entries()) {
    CHECK(target.push(entry));
  }

  CHECK(target.pop() == &sourceNew);
  CHECK(target.pop() == &sourceMiddle);
  CHECK(target.pop() == &sourceOld);
  CHECK(target.pop() == &targetNew);
  CHECK(target.pop() == &targetOld);
}

int main() { return RUN_TESTS(); }
