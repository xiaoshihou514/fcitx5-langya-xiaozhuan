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
    // 持久化：把当前模式写回默认配置，跨输入框/切换/重启保持
    // （真机反馈：此前每次激活都重置为固定默认，需反复切换）
    config_.sealByDefault.setValue(st->sealMode);
    fcitx::safeSaveAsIni(config_, "conf/langya.conf");
    updateUI(ic);
    modeAction_.update(ic);
    FCITX_INFO() << "琅琊模式切换 → "
                 << (st->sealMode ? "小篆" : "楷化") << "（已持久化）";
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
    auto candList = ic->inputPanel().candidateList();

    // ── 候选导航（复用 fcitx5 通用候选接口，pinyin 引擎同款）──
    // 翻页：PageUp/- 上一页，PageDown/=/+ 下一页（fcitx5-android
    // 候选栏左右箭头走 pageable 接口，同样由此生效）
    if (composing && candList) {
        bool nav = false;
        if (auto *pageable = candList->toPageable()) {
            if ((key.check(FcitxKey_Page_Up) || key.check(FcitxKey_minus))
                && noModifier(key.states())) {
                if (pageable->hasPrev()) {
                    pageable->prev();
                    nav = true;
                } else {
                    event.filterAndAccept();
                    return;
                }
            }
            if ((key.check(FcitxKey_Page_Down) || key.check(FcitxKey_equal)
                 || key.check(FcitxKey_plus)) && noModifier(key.states())) {
                pageable->next();
                nav = true;
            }
        }
        if (auto *movable = candList->toCursorMovable()) {
            if (noModifier(key.states())
                && (key.check(FcitxKey_Right) || key.check(FcitxKey_Down))) {
                movable->nextCandidate();
                nav = true;
            }
            if (noModifier(key.states())
                && (key.check(FcitxKey_Left) || key.check(FcitxKey_Up))) {
                movable->prevCandidate();
                nav = true;
            }
        }
        if (nav) {
            ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
            event.filterAndAccept();
            return;
        }
    }

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
    // 空格：上屏当前高亮候选（未浏览时即首选；方向键移动后为所指项）
    if (plainSym(key, FcitxKey_space)) {
        auto cands = ic->inputPanel().candidateList();
        if (cands && cands->size() > 0) {
            int cur = cands->cursorIndex();
            cands->candidate(cur < 0 ? 0 : cur).select(ic);
            event.filterAndAccept();
        }
        return;
    }
    // 数字：选当前页第 idx 个候选（1234567890 顺序；翻页后
    // 指新页——与 pinyin 的 keyListIndex(selectionKeys) 同语义）
    if (key.sym() >= FcitxKey_0 && key.sym() <= FcitxKey_9
        && noModifier(key.states()) && composing) {
        int idx = key.digitSelection();
        if (candList && idx >= 0 && idx < candList->size()) {
            candList->candidate(idx).select(ic);
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

    // 预编辑（与 fcitx5 拼音同款）：
    //   客户端预编辑（应用输入框内嵌）＝ 自动转换整句的楷化显示
    //   ＝ 已选句 + 当前最优候选（打 nihao 输入框直接显示「你好」）；
    //   面板预编辑（候选栏上方）＝ 拼音串（libime 带音节分隔）
    std::string sentence = ctx.selectedSentence();
    if (!ctx.candidatesToCursor().empty()) {
        sentence += ctx.candidatesToCursor()[0].toString();
    }
    fcitx::Text clientPreedit(
        charmap().convert(sentence, false).first);
    clientPreedit.setCursor(clientPreedit.textLength());
    panel.setClientPreedit(clientPreedit);
    panel.setPreedit(fcitx::Text(ctx.preedit()));

    auto candList = std::make_unique<fcitx::CommonCandidateList>();
    candList->setPageSize(config_.pageSize.value());
    // 翻页保持页内高亮位置（第 x 页选第 y 项，翻页后仍指第 y 项）
    candList->setCursorPositionAfterPaging(
        fcitx::CursorPositionAfterPaging::SameAsLast);
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
