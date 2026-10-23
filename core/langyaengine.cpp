#include "langyaengine.h"

#include <fcitx-config/iniparser.h>
#include <fcitx-utils/cutf8.h>
#include <fcitx-utils/utf8.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx-utils/stringutils.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/statusarea.h>
#include <fcitx/userinterface.h>
#include <fcitx/userinterfacemanager.h>

#include <libime/pinyin/pinyindictionary.h>
#include <libime/core/userlanguagemodel.h>
#include <libime/core/languagemodel.h>
#include <cstdlib>
#include <fstream>
#include <memory>

namespace langya {

/* ── 汉字映射 ───────────────────────────────────────────── */

bool CharMap::load() {
    const auto path = fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData, "langya/langya.map");
    if (path.empty()) {
        return false;
    }
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        const auto cols = fcitx::stringutils::split(line, "\t");
        if (cols.size() < 3) {
            continue;
        }
        // 列：汉字 \t 小篆码点(HEX) \t 楷化字
        if (cols[0].empty()) {
            continue;
        }
        auto cp = fcitx::utf8::getChar(cols[0]);
        try {
            seal_[cp] = std::stoul(cols[1], nullptr, 16);
        } catch (const std::exception &) {
            continue;
        }
        kai_[cp] = cols[2];
    }
    return !seal_.empty();
}

std::pair<std::string, bool> CharMap::convert(const std::string &hanzi,
                                              bool seal) const {
    std::string out;
    bool miss = false;
    auto iter = hanzi.begin();
    while (iter != hanzi.end()) {
        std::uint32_t cp = 0;
        auto next = fcitx::utf8::getNextChar(iter, hanzi.end(), &cp);
        std::string ch(iter, next);
        iter = next;
        if (seal) {
            auto it = seal_.find(cp);
            if (it != seal_.end()) {
                out += fcitx::utf8::UCS4ToUTF8(it->second);
                continue;
            }
        } else {
            auto it = kai_.find(cp);
            if (it != kai_.end() && !it->second.empty()) {
                out += it->second;
                continue;
            }
        }
        miss = true;
        out += ch;  // 未收字回退原字
    }
    return {out, miss};
}

/* ── 键盘内「篆/楷」切换按钮 ─────────────────────────────── */

LangyaModeAction::LangyaModeAction(LangyaEngine *engine)
    : engine_(engine) {
    setCheckable(true);
}

std::string LangyaModeAction::shortText(fcitx::InputContext *ic) const {
    return engine_->state(ic)->sealMode ? "篆" : "楷";
}

bool LangyaModeAction::isChecked(fcitx::InputContext *ic) const {
    return engine_->state(ic)->sealMode;
}

void LangyaModeAction::activate(fcitx::InputContext *ic) {
    engine_->toggleMode(ic);
}

/* ── 候选词：显示原词，上屏按模式转换 ───────────────────── */

class LangyaCandidateWord : public fcitx::CandidateWord {
public:
    LangyaCandidateWord(LangyaEngine *engine, std::string hanzi)
        : CandidateWord(fcitx::Text(hanzi)), engine_(engine),
          hanzi_(std::move(hanzi)) {}

    void select(fcitx::InputContext *ic) const override {
        auto converted = engine_->charmap().convert(
            hanzi_, engine_->state(ic)->sealMode);
        engine_->commitEntry(ic, hanzi_, converted.second);
    }

private:
    LangyaEngine *engine_;
    std::string hanzi_;
};

/* ── 状态与生命周期 ─────────────────────────────────────── */

LangyaState::LangyaState(LangyaEngine *engine)
    : context(&engine->ime()) {
    context.setMaxSentenceLength(35);
}

namespace {
bool noModifier(const fcitx::KeyStates &states) {
    const auto mod = fcitx::KeyStates(fcitx::KeyState::Ctrl)
        | fcitx::KeyStates(fcitx::KeyState::Alt)
        | fcitx::KeyStates(fcitx::KeyState::Shift)
        | fcitx::KeyStates(fcitx::KeyState::Super);
    return !(states & mod);
}

bool plainLower(const fcitx::Key &key) {
    return key.sym() >= FcitxKey_a && key.sym() <= FcitxKey_z
        && noModifier(key.states());
}

bool plainSym(const fcitx::Key &key, fcitx::KeySym sym) {
    return key.sym() == sym && noModifier(key.states());
}
} // namespace

LangyaEngine::LangyaEngine(fcitx::Instance *instance)
    : instance_(instance),
      ime_(std::make_unique<libime::PinyinDictionary>(),
           std::make_unique<libime::UserLanguageModel>(
               libime::DefaultLanguageModelResolver::instance()
                   .languageModelFileForLanguage("zh_CN"))),
      factory_([this](fcitx::InputContext &) {
          return new LangyaState(this);
      }),
      modeAction_(this) {
    instance_->inputContextManager().registerProperty("langyaState",
                                                      &factory_);
    // 拼音系统词典（宿主自带 sc.dict，与 fcitx5 拼音共享；
    // Android 经 XDG_DATA_DIRS 生效；LANGYA_LIBIME_DICT 可显式覆盖）
    const char *dictEnv = std::getenv("LANGYA_LIBIME_DICT");
    const std::string dictPath =
        (dictEnv && *dictEnv)
        ? std::string(dictEnv)
        : fcitx::StandardPaths::global()
              .locate(fcitx::StandardPathsType::Data, "libime/sc.dict")
              .string();
    if (!dictPath.empty()) {
        ime_.dict()->load(libime::PinyinDictionary::SystemDict, dictPath.c_str(),
                          libime::PinyinDictFormat::Binary);
        FCITX_INFO() << "琅琊：已加载 libime 拼音词典 " << dictPath;
    } else {
        FCITX_ERROR() << "琅琊：未找到 libime/sc.dict，候选将不可用";
    }
    if (charmap_.load()) {
        FCITX_INFO() << "琅琊：映射表加载成功";
    } else {
        FCITX_ERROR() << "琅琊：未找到 langya/langya.map";
    }
    modeAction_.registerAction("langya-mode",
                               &instance_->userInterfaceManager());
    reloadConfig();
}

LangyaEngine::~LangyaEngine() = default;

void LangyaEngine::activate(const fcitx::InputMethodEntry & /*entry*/,
                            fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    auto *st = state(ic);
    st->context.clear();
    st->sealMode = config_.sealByDefault.value();
    ic->statusArea().addAction(fcitx::StatusGroup::InputMethod,
                               &modeAction_);
    modeAction_.update(ic);
    FCITX_INFO() << "琅琊引擎激活（模式="
                 << (st->sealMode ? "小篆" : "楷化") << "）";
}

void LangyaEngine::reset(const fcitx::InputMethodEntry & /*entry*/,
                         fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    state(ic)->context.clear();
    updateUI(ic);
}

LangyaState *LangyaEngine::state(fcitx::InputContext *ic) {
    return ic->propertyFor(&factory_);
}

void LangyaEngine::toggleMode(fcitx::InputContext *ic) {
    auto *st = state(ic);
    st->sealMode = !st->sealMode;
    updateUI(ic);
    modeAction_.update(ic);
}

/* ── 键处理 ─────────────────────────────────────────────── */

void LangyaEngine::keyEvent(const fcitx::InputMethodEntry & /*entry*/,
                            fcitx::KeyEvent &event) {
    if (event.isRelease()) {
        return;
    }
    const auto &key = event.key();
    auto *ic = event.inputContext();
    auto *st = state(ic);

    // Ctrl+Shift+S：模式切换（大小写归一化后 sym 可为 s 或 S）
    if (key.states() == fcitx::KeyState::Ctrl_Shift
        && (key.sym() == FcitxKey_s || key.sym() == FcitxKey_S)) {
        toggleMode(ic);
        event.filterAndAccept();
        return;
    }

    auto &ctx = st->context;
    const bool composing = !ctx.userInput().empty();

    if (plainSym(key, FcitxKey_BackSpace)) {
        if (composing) {
            ctx.backspace();
            updateUI(ic);
            event.filterAndAccept();
        }
        return;
    }
    if (plainSym(key, FcitxKey_Escape)) {
        if (composing) {
            ctx.clear();
            updateUI(ic);
            event.filterAndAccept();
        }
        return;
    }
    // 空格：上屏首选
    if (plainSym(key, FcitxKey_space)) {
        if (!ctx.candidatesToCursor().empty()) {
            commitEntry(ic,
                        ctx.candidatesToCursor()[0].toString(), false);
            event.filterAndAccept();
        }
        return;
    }
    // 数字：候选选择（1234567890 顺序）
    if (key.sym() >= FcitxKey_0 && key.sym() <= FcitxKey_9
        && noModifier(key.states()) && composing) {
        int idx = key.digitSelection();
        const auto &cands = ctx.candidatesToCursor();
        if (idx >= 0 && static_cast<size_t>(idx) < cands.size()) {
            commitEntry(ic, cands[idx].toString(), false);
            event.filterAndAccept();
            return;
        }
        event.filterAndAccept();
        return;
    }
    // 小写字母：进入拼音缓冲（libime 处理切分/简拼/模糊）
    if (plainLower(key)) {
        ctx.type(std::string(1,
                             static_cast<char>(key.sym() - FcitxKey_a
                                               + 'a')));
        updateUI(ic);
        event.filterAndAccept();
        return;
    }
    if (composing && noModifier(key.states())) {
        // 组字中的其余无修饰键吞掉，防泄入应用
        event.filterAndAccept();
        return;
    }
}

/* ── 界面刷新 ───────────────────────────────────────────── */

void LangyaEngine::updateUI(fcitx::InputContext *ic) {
    auto *st = state(ic);
    auto &ctx = st->context;
    auto &panel = ic->inputPanel();

    if (ctx.userInput().empty()) {
        panel.reset();
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        return;
    }

    // 预编辑显示在候选面板（拼音串，libime 自带分隔）；
    // 客户端预编辑显示已选汉字的楷化形式（可读）
    panel.setPreedit(fcitx::Text(ctx.preedit()));
    auto selected = ctx.selectedSentence();
    if (!selected.empty()) {
        panel.setClientPreedit(fcitx::Text(
            charmap().convert(selected, false).first));
    } else {
        panel.setClientPreedit(fcitx::Text(""));
    }

    auto candList = std::make_unique<fcitx::CommonCandidateList>();
    candList->setPageSize(config_.pageSize.value());
    candList->setSelectionKey(fcitx::KeyList{
        fcitx::Key(FcitxKey_1), fcitx::Key(FcitxKey_2),
        fcitx::Key(FcitxKey_3), fcitx::Key(FcitxKey_4),
        fcitx::Key(FcitxKey_5), fcitx::Key(FcitxKey_6),
        fcitx::Key(FcitxKey_7), fcitx::Key(FcitxKey_8),
        fcitx::Key(FcitxKey_9), fcitx::Key(FcitxKey_0)});
    for (const auto &cand : ctx.candidatesToCursor()) {
        candList->append<LangyaCandidateWord>(this, cand.toString());
    }
    if (candList->size() > 0) {
        candList->setGlobalCursorIndex(0);
    }
    panel.setCandidateList(std::move(candList));

    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    FCITX_INFO() << "琅琊查表 " << ctx.userInput()
                 << " 命中 " << ctx.candidatesToCursor().size();
}

/* ── 提交 ───────────────────────────────────────────────── */

void LangyaEngine::commitEntry(fcitx::InputContext *ic,
                               const std::string &hanzi, bool miss) {
    auto *st = state(ic);
    auto [out, m] = charmap().convert(hanzi, st->sealMode);
    ic->commitString(out);
    st->context.clear();
    ic->inputPanel().reset();
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    FCITX_INFO() << "琅琊上屏 " << hanzi << " → " << out
                 << (m || miss ? "（含未收字）" : "");
}

/* ── 配置 ───────────────────────────────────────────────── */

void LangyaEngine::reloadConfig() {
    fcitx::readAsIni(config_, "conf/langya.conf");
}

void LangyaEngine::setConfig(const fcitx::RawConfig &config) {
    config_.load(config, true);
    fcitx::safeSaveAsIni(config_, "conf/langya.conf");
}

} // namespace langya

FCITX_ADDON_FACTORY(langya::LangyaEngineFactory);
