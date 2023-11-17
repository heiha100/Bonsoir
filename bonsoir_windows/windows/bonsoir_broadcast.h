#pragma once

#include "bonsoir_action.h"

using namespace flutter;

namespace bonsoir_windows {
  class BonsoirBroadcast : public BonsoirAction {
   public:
    BonsoirService service;

    BonsoirBroadcast(
      int _id,
      bool _printLogs,
      flutter::BinaryMessenger *_binaryMessenger,
      std::function<void()> onDispose,
      BonsoirService _service
    );

    void start() override;

    void dispose() override;

   private:
    DNS_SERVICE_REGISTER_REQUEST registerRequest{};
  };

  void registerCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance);
}  // namespace bonsoir_windows