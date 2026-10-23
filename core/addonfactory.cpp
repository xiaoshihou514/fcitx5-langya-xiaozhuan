#include "langyaengine.h"

#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>

fcitx::AddonInstance *
langya::LangyaEngineFactory::create(fcitx::AddonManager *manager) {
    // 引擎不依赖 AddonManager 其他服务，仅取 Instance
    return new langya::LangyaEngine(manager->instance());
}
