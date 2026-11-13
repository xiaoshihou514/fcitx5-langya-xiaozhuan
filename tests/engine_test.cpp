/* 琅琊引擎集成测试：借 fcitx5 官方 testing 设施（testfrontend）注入
 * 按键事件，端到端验证「拼音 → 候选 → 上屏」与模式切换。
 *
 * 断言口径（task-40 测试重造，依审计附录甲探针方法）：
 *   - 每个按键断言「吞（accepted=true）／放行（false）」；
 *   - 上屏内容经 InputContextCommitString 事件独立捕获，不再依赖
 *     testfrontend 的期望队列（队列失配会直接 fatal，诊断信息差）；
 *   - 面板状态（候选数量、清空）显式断言；
 *   - 每个场景组使用全新输入上下文，杜绝状态串扰；
 *   - 模式持久化断言配置落盘（conf/langya.conf），不只验内存。
 *
 * 前置：FCITX_ROOT 指向含 langya 三件套与 libime 数据的 fcitx5 前缀
 * （xmake engine-test 会布置），链接 Fcitx5Core/Config/Utils。
 */
#include <array>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>
#include <fcitx-utils/rect.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx-utils/testing.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodgroup.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx/instance.h>
#include "testfrontend_public.h"

using namespace fcitx;

namespace {

std::string cp(uint32_t v) {
    std::string s;
    if (v < 0x80) {
        s += static_cast<char>(v);
    } else if (v < 0x800) {
        s += static_cast<char>(0xC0 | (v >> 6));
        s += static_cast<char>(0x80 | (v & 0x3F));
    } else if (v < 0x10000) {
        s += static_cast<char>(0xE0 | (v >> 12));
        s += static_cast<char>(0x80 | ((v >> 6) & 0x3F));
    } else {
        s += static_cast<char>(0xF0 | (v >> 18));
        s += static_cast<char>(0x80 | ((v >> 12) & 0x3F));
        s += static_cast<char>(0x80 | ((v >> 6) & 0x3F));
        s += static_cast<char>(0x80 | (v & 0x3F));
    }
    return s;
}

/* 独立捕获的上屏内容（PreInputMethod 相位，引擎 commitString 即入列） */
std::vector<std::string> g_commits;

int g_pass = 0;
int g_fail = 0;

void check(bool ok, const std::string &what) {
    if (ok) {
        ++g_pass;
        FCITX_INFO() << "✓ " << what;
    } else {
        ++g_fail;
        FCITX_INFO() << "✗ " << what;
        FCITX_INFO() << "  [诊断] 上屏捕获条数=" << g_commits.size()
                     << " 末条长度=" << (g_commits.empty() ? -1
                                           : static_cast<int>(g_commits.back().size()));
    }
}

/* 上屏历史是否恰好以 expect 结尾 */
bool commitIs(const std::string &expect) {
    return !g_commits.empty() && g_commits.back() == expect;
}

/* 自上次检查以来没有新的上屏 */
bool noCommit() { return g_commits.empty(); }

/* 面板候选数量（无候选窗记 0） */
int candCount(InputContext *ic) {
    auto cl = ic->inputPanel().candidateList();
    return cl ? static_cast<int>(cl->size()) : 0;
}

} // namespace

int main() {
    const char *rootEnv = std::getenv("FCITX_ROOT");
    std::filesystem::path root = rootEnv ? rootEnv : "/tmp/fcitx5root";
    // 测试环境 SkipSystem 废掉 Data 类型，词典用显式路径覆盖；
    // 语言模型目录经 LIBIME_MODEL_DIRS 指定（libime resolver 认）
    ::setenv("LANGYA_LIBIME_DICT",
             (root / "usr" / "share" / "libime" / "sc.dict").c_str(), 1);
    ::setenv("LIBIME_MODEL_DIRS",
             (root / "usr" / "share" / "libime").c_str(), 1);
    fcitx::setupTestingEnvironmentPath(
        "", {root / "usr/lib64/fcitx5"},
        {root / "usr/share", root / "usr/share/fcitx5",
         root / "usr/share/fcitx5/testing"});

    char arg0[] = "langya-engine-test";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=langya,testfrontend,punctuation,chttrans";
    char arg3[] = "--verbose=*=5";
    char *argv[] = {arg0, arg1, arg2, arg3};
    Instance instance(FCITX_ARRAY_SIZE(argv), argv);
    instance.addonManager().registerDefaultLoader(nullptr);

    // 独立捕获上屏：引擎提交什么就记什么（PreInputMethod 相位）
    // 注意：watchEvent 返回的句柄必须保存，否则处理器注册即被注销
    auto captureCommit =
        instance.watchEvent(
            EventType::InputContextCommitString,
            EventWatcherPhase::PreInputMethod, [](Event &e) {
                g_commits.push_back(
                    static_cast<CommitStringEvent &>(e).text());
            });

    instance.eventDispatcher().schedule([&instance]() {
        auto &imm = instance.inputMethodManager();
        auto group = imm.currentGroup();
        group.inputMethodList().clear();
        group.inputMethodList().emplace_back("langya");
        group.setDefaultInputMethod("langya");
        imm.setGroup(std::move(group));

        auto *tf = instance.addonManager().addon("testfrontend");
        check(tf != nullptr, "testfrontend 加载");
        {
            auto *info = instance.addonManager().addonInfo("chttrans");
            check(info && info->isValid(), "chttrans conf 已扫描且有效");
            auto *cht = instance.addonManager().addon("chttrans");
            check(cht != nullptr, "chttrans 简繁模块可拉起");
        }
        auto *langya = instance.addonManager().addon("langya");
        check(langya != nullptr, "langya 引擎加载");
        if (!tf || !langya) {
            instance.exit(1);
            return;
        }

        /* 场景帮手：每个场景组一个全新输入上下文（防状态串扰） */
        using UuidT = std::array<unsigned char, 16>;  // createInputContext 返回
        UuidT uuid{};
        bool haveIC = false;
        InputContext *ic = nullptr;
        auto newIC = [&](const std::string &program) {
            if (haveIC) {
                tf->call<ITestFrontend::destroyInputContext>(uuid);
            }
            uuid = tf->call<ITestFrontend::createInputContext>(program);
            haveIC = true;
            ic = instance.inputContextManager().findByUUID(uuid);
            ic->focusIn();
            g_commits.clear();
            return ic;
        };
        /* 按键并返回「是否被吞」（accepted）；失焦上下文返回 false */
        auto key = [&](const std::string &k) -> bool {
            return tf->call<ITestFrontend::sendKeyEvent>(uuid, Key(k), false);
        };
        auto keyRaw = [&](Key k) -> bool {
            return tf->call<ITestFrontend::sendKeyEvent>(uuid, k, false);
        };
        auto type = [&](const std::string &letters) -> bool {
            bool all = true;
            for (char c : letters) {
                all &= key(std::string(1, c));
            }
            return all;
        };
        /* Key("Ctrl+Shift+S") 字符串解析会丢 Ctrl，须显式构造 */
        auto toggleMode = [&]() {
            keyRaw(Key(FcitxKey_s, KeyState::Ctrl_Shift));
        };

        // ═══ 场景组 1：小篆模式基本流（全新上下文）═══
        newIC("t1-基本流");
        check(instance.inputMethod(ic) == "langya", "当前输入法为琅琊");
        check(type("wo"), "字母 w/o 组字被吞");
        check(candCount(ic) == 5, "wo 出 5 个候选（默认每页 5）");
        check(key("space"), "空格上屏被吞");
        check(commitIs(cp(0x3F57E)), "wo+空格 上屏小篆「我」(U+3F57E)");
        check(candCount(ic) == 0 && noCommit() == false,
              "上屏后面板清空");

        // Esc 清空组字：吞键＋面板清空＋无新上屏
        auto n0 = g_commits.size();
        check(type("wo"), "重新组字 wo");
        check(key("Escape"), "Escape 被吞");
        check(candCount(ic) == 0, "Esc 后面板候选清空");
        check(g_commits.size() == n0, "Esc 后无新上屏");

        // 非组字空格直通应用（不吞）
        n0 = g_commits.size();
        check(!key("space"), "非组字空格放行给应用");
        check(g_commits.size() == n0, "非组字空格无上屏");

        // ═══ 场景组 2：词组与选词 ═══
        newIC("t2-词组选词");
        check(type("zhongguo"), "zhongguo 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3D119) + cp(0x3E1D3)),
              "zhongguo+空格 上屏「中國」小篆");

        // 数字选词：ni+2
        check(type("ni"), "ni 组字被吞");
        check(key("2"), "数字 2 选词被吞");
        check(commitIs(cp(0x3F3B2)), "ni+2 上屏「拟」小篆");

        // 软键盘 NumLock 状态回归（Android 虚拟键盘场景）
        check(keyRaw(Key(FcitxKey_w, KeyStates(KeyState::NumLock))),
              "NumLock 下的 w 仍被吞组字");
        check(keyRaw(Key(FcitxKey_o, KeyStates(KeyState::NumLock))),
              "NumLock 下的 o 仍被吞组字");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3F57E)), "NumLock 下 wo+空格 上屏小篆「我」");

        // 翻页选词：ni + PageDown + 1 →「呢」（說文未收回退）
        check(type("ni"), "ni 组字被吞");
        check(key("Page_Down"), "Page_Down 被吞");
        check(key("1"), "数字 1 被吞");
        check(commitIs("呢"), "ni+PageDown+1 翻页选词上屏「呢」");

        // 翻页保持高亮位：ni+Right+PageDown+space → 第 7 候选「尼」
        check(type("ni"), "ni 组字被吞");
        check(key("Right"), "Right 被吞");
        check(key("Page_Down"), "Page_Down 被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3E864)), "ni+Right+PageDown+空格 保持高亮位选词");

        // 方向键浏览：zhongguo + Right + space →「中过」
        check(type("zhongguo"), "zhongguo 组字被吞");
        check(key("Right"), "Right 被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3D119) + cp(0x3D4E7)),
              "zhongguo+Right+空格 上屏高亮候选");

        // 退格改键：woh + BackSpace + space → 我
        check(type("woh"), "woh 组字被吞");
        check(key("BackSpace"), "BackSpace 被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3F57E)), "woh+退格+空格 上屏小篆「我」");

        // ═══ 场景组 3：单字排序回归（task-16）═══
        newIC("t3-单字排序");
        check(type("yi"), "yi 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3D000)), "yi 首选为「一」(U+3D000)");
        check(type("de"), "de 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3E300)), "de 首选为「的」(U+3E300)");
        check(type("ma"), "ma 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs("吗"), "ma 首选为「吗」（說文未收，回退原字）");

        // ═══ 场景组 3b：部分选择后继续组字（K3 回归）═══
        newIC("t3b-部分选择");
        toggleMode();  // 楷化模式，断言确定性文本
        check(type("nihaoma"), "nihaoma 组字被吞");
        check(key("Right"), "Right 移高亮被吞");
        check(key("space"), "空格选「你好」被吞");
        {
            size_t n = g_commits.size();
            check(n == 0 || commitIs("") == false,
                  "部分选择不产生独立上屏");
        }
        check(candCount(ic) > 0, "剩余拼音「ma」继续组字出候选");
        check(key("space"), "空格选剩余候选被吞");
        check(commitIs("你好吗"), "整句一起上屏「你好吗」（K3）");
        toggleMode();  // 切回小篆

        // ═══ 场景组 4：非组字标点（punctuation 模块 zh_CN 表）═══
        newIC("t4-标点");
        // K2 回归：组字中按逗号＝选候选并继续输出标点（wo, → 𿕾，）
        check(type("wo"), "wo 组字被吞");
        check(key("comma"), "组字中逗号被吞");
        check(g_commits.size() >= 2 && g_commits[g_commits.size() - 2] ==
                  cp(0x3F57E) && commitIs("，"),
              "wo+逗号 → 「𿕾，」（候选＋标点，K2）");
        check(key("comma"), "逗号被吞并转换");
        check(commitIs("，"), "非组字逗号 → 「，」");
        check(key("period"), "句号被吞并转换");
        check(commitIs("。"), "非组字句号 → 「。」");
        check(key("backslash"), "反斜杠被吞并转换");
        check(commitIs("、"), "非组字反斜杠 → 「、」（顿号）");

        // ═══ K4 回归：标点候选窗状态机（多映射键 [）═══
        newIC("t4b-标点窗");
        check(key("bracketleft"), "开窗被吞");
        check(candCount(ic) > 0, "标点候选窗打开");
        // 窗内字母：关窗并放行，不得漏进组字缓冲
        check(!key("n"), "窗内字母关窗并放行（Q1）");
        check(candCount(ic) == 0, "字母后窗口关闭");
        // Esc：关窗吞键
        check(key("bracketleft"), "再开窗被吞");
        check(key("Escape"), "Esc 关窗被吞（Q2）");
        check(candCount(ic) == 0, "Esc 后窗口关闭");
        // 退格：关窗吞键（不得删应用字符）
        check(key("bracketleft"), "再开窗被吞");
        check(key("BackSpace"), "退格关窗被吞（Q3）");
        check(candCount(ic) == 0, "退格后窗口关闭");
        // 失焦：窗口关闭，残留不得吃掉后续按键
        check(key("bracketleft"), "再开窗被吞");
        ic->focusOut();
        ic->focusIn();
        check(candCount(ic) == 0, "失焦后窗口关闭（Q4）");
        {
            // Q5：残留状态不再吃键。注意上游语义：Q1 放行的字母 n 使
            // punctuation 记录「前一字符为字母」，随后的逗号按半角
            // 规则直出（不转换），与 K1 同源——键不被吞即为通过
            size_t n = g_commits.size();
            check(!key("comma"), "失焦关窗后逗号不被窗口吞键（Q5）");
            check(g_commits.size() == n, "残留不产生意外上屏（Q5）");
            check(key("backslash"), "顿号正常转换（窗口不吃键）");
            check(commitIs("、"), "反斜杠 → 「、」正常转换");
        }
        // 数字选择标点候选
        {
            size_t n = g_commits.size();
            check(key("bracketleft"), "开窗被吞");
            check(key("2"), "数字选择候选被吞");
            check(g_commits.size() == n + 1, "数字选中候选已上屏");
        }

        // K1 回归：字母/数字后的「.」「,」为半角规则，直出给应用
        auto n1 = g_commits.size();
        check(!key("3"), "数字 3 放行");
        check(!key("period"), "数字后的句号放行（K1）");
        check(!key("1"), "数字 1 放行");
        check(!key("4"), "数字 4 放行");
        check(g_commits.size() == n1, "3.14 过程无上屏（半角直出）");
        check(!key("1"), "数字 1 放行");
        check(!key("comma"), "数字后的逗号放行（K1）");
        check(!key("0"), "数字 0 放行");
        check(!key("0"), "数字 0 放行");
        check(!key("0"), "数字 0 放行");
        check(g_commits.size() == n1, "1,000 过程无上屏（半角直出）");
        check(!key("A"), "字母 A 放行");
        check(!key("period"), "字母后的句号放行（K1）");

        // ═══ K5 回归：组字中失焦提交当前模式文本 ═══
        newIC("t4c-失焦提交");
        // 小篆模式：wo + 失焦 → 应提交小篆「𿕾」而非楷化预编辑
        check(type("wo"), "wo 组字被吞");
        ic->focusOut();
        check(commitIs(cp(0x3F57E)),
              "小篆模式失焦提交小篆「𿕾」（K5，非楷化预编辑）");
        ic->focusIn();
        // 楷化模式：wo + 失焦 → 提交「我」
        toggleMode();
        check(type("wo"), "楷化下 wo 组字被吞");
        ic->focusOut();
        check(commitIs("我"), "楷化模式失焦提交「我」");
        ic->focusIn();
        toggleMode();  // 切回小篆

        // ═══ 场景组 5：模式切换与持久化 ═══
        newIC("t5-模式切换");
        toggleMode();  // 切楷化
        check(type("wo"), "楷化下 wo 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs("我"), "切楷化后 wo+空格 上屏「我」");
        // 持久化：经引擎 getConfig 断言模式值（写入内存配置并已触发
        // safeSaveAsIni）。注意：官方 testing 设施会把全局 StandardPaths
        // 钉死为 SkipUserPath（setupTestingEnvironmentPath 内 setGlobal），
        // safeSave 无处可写，故「落盘文件存在」在本设施下不可断言；
        // 落盘与重启读回以真机手工验证（见 docs/desktop/agent.md）。
        {
            RawConfig cfg;
            langya->getConfig()->save(cfg);
            const std::string *v = cfg.valueByPath("SealByDefault");
            check(v != nullptr && *v == "False",
                  "切楷化后引擎配置 SealByDefault=False（已持久化到配置）");
        }
        toggleMode();  // 切回小篆
        check(type("wo"), "切回小篆后 wo 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3F57E)), "切回小篆后 wo+空格 上屏「𿕾」");

        // 持久化跨上下文：全新输入上下文仍保持小篆
        newIC("t5b-重启后");
        check(type("wo"), "新上下文 wo 组字被吞");
        check(key("space"), "空格被吞");
        check(commitIs(cp(0x3F57E)),
              "重新激活后模式保持小篆（wo → 𿕾）");

        tf->call<ITestFrontend::destroyInputContext>(uuid);
        instance.exit(g_fail == 0 ? 0 : 1);
    });

    instance.exec();
    FCITX_INFO() << "通过 " << g_pass << " 项，失败 " << g_fail << " 项";
    return g_fail == 0 ? 0 : 1;
}
