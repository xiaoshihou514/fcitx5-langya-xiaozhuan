/* 琅琊（Langya）说文小篆输入法 — fcitx5 引擎。
 *
 * 架构：拼音层直接复用 libime 的 PinyinIME（fcitx5 拼音同款内核，
 * 词典/语言模型用宿主自带的 sc.dict + zh_CN.lm，零数据重复），
 * 候选词经琅琊映射表（data/langya.map，zhuan 查表链离线导出）
 * 逐字转换为小篆码点（U+3D000–3FC3F）或楷化字后上屏。
 *
 * 行为与 fcitx5 拼音一致：简拼/全拼/词组/模糊匹配由 libime 提供，
 * 预编辑（ni'hao）显示在候选面板而非应用文本框。
 * 模式切换：键盘「…」面板的「篆/楷」按钮，或 Ctrl+Shift+S。
 */
#ifndef LANGYA_ENGINE_H_
#define LANGYA_ENGINE_H_

#include <fcitx-config/configuration.h>
#include <fcitx-utils/key.h>
#include <fcitx/action.h>
#include <fcitx/addonfactory.h>
#include <fcitx/event.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyinime.h>

#include <cstdint>
#include <string>
#include <unordered_map>

namespace fcitx {
class Instance;
class AddonManager;
class AddonInstance;
}

namespace langya {

/* 配置（fcitx5 配置工具自动生成界面） */
FCITX_CONFIGURATION(
    LangyaConfig,
    fcitx::Option<bool> sealByDefault{
        this, "SealByDefault", "默认输出小篆码点（否则输出楷化字）", true};
    fcitx::Option<int, fcitx::IntConstrain> pageSize{
        this, "PageSize", "每页候选数", 5, fcitx::IntConstrain(3, 10)};);

/* 汉字 → (小篆码点, 楷化字) 映射（langya.map，导出自 zhuan 查表链） */
class CharMap {
public:
    bool load();
    /* 逐字转换：seal=true 上屏小篆码点，否则楷化字；未收字回退原字，
     * 第二返回值为是否存在未收字 */
    std::pair<std::string, bool> convert(const std::string &hanzi,
                                         bool seal) const;

private:
    std::unordered_map<std::uint32_t, std::uint32_t> seal_;
    std::unordered_map<std::uint32_t, std::string> kai_;
};

class LangyaEngine;

/* 每个输入上下文一份：libime 拼音上下文 + 输出模式 */
struct LangyaState : public fcitx::InputContextProperty {
    LangyaState(LangyaEngine *engine);
    libime::PinyinContext context;
    bool sealMode = true;
};

/* 键盘内「篆/楷」切换按钮（StatusArea action） */
class LangyaModeAction : public fcitx::Action {
public:
    explicit LangyaModeAction(class LangyaEngine *engine);
    std::string shortText(fcitx::InputContext *ic) const override;
    std::string icon(fcitx::InputContext *) const override { return {}; }
    bool isChecked(fcitx::InputContext *ic) const override;
    void activate(fcitx::InputContext *ic) override;

private:
    class LangyaEngine *engine_;
};

class LangyaEngine : public fcitx::InputMethodEngineV2 {
    friend class LangyaModeAction;

public:
    explicit LangyaEngine(fcitx::Instance *instance);
    ~LangyaEngine() override;

    void activate(const fcitx::InputMethodEntry &entry,
                  fcitx::InputContextEvent &event) override;
    void reset(const fcitx::InputMethodEntry &entry,
               fcitx::InputContextEvent &event) override;
    void keyEvent(const fcitx::InputMethodEntry &entry,
                  fcitx::KeyEvent &keyEvent) override;

    const fcitx::Configuration *getConfig() const override {
        return &config_;
    }
    void setConfig(const fcitx::RawConfig &config) override;
    void reloadConfig() override;

    /* 候选词回调：按当前上下文模式提交并复位 */
    void commitEntry(fcitx::InputContext *ic, const std::string &hanzi,
                     bool miss);
    void toggleMode(fcitx::InputContext *ic);
    LangyaConfig &config() { return config_; }
    LangyaState *state(fcitx::InputContext *ic);

    libime::PinyinIME &ime() { return ime_; }
    const CharMap &charmap() const { return charmap_; }

private:
    void updateUI(fcitx::InputContext *ic);

    fcitx::Instance *instance_;
    fcitx::FactoryFor<LangyaState> factory_;
    libime::PinyinIME ime_;
    CharMap charmap_;
    LangyaConfig config_;
    LangyaModeAction modeAction_;
};

class LangyaEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override;
};

} // namespace langya

#endif // LANGYA_ENGINE_H_
