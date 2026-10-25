/* 琅琊引擎集成测试：借 fcitx5 官方 testing 设施（testfrontend）注入
 * 按键事件，端到端验证「拼音 → 候选 → 上屏」与模式切换。
 *
 * 前置（run.sh 负责）：
 *   - FCITX_ADDON_DIRS/FCITX_DATA_DIRS 指向包含 langya 三件套的 fcitx5 目录
 *   - 链接 Fcitx5Core/Config/Utils
 *
 * 用例：
 *   1. 小篆模式默认：wo+空格 → 上屏 我(U+3F57E)
 *   2. Ctrl+Shift+S 切楷化：wo+空格 → 上屏 我
 *   3. 词组：zhongguo+空格 → 上屏 中(3D119)國(3E1D3)
 *   4. 数字选词：ni+2 → 上屏 呢（說文未收，按原字回退）
 *   5. 退格：woh+退格+空格 → 我(U+3F57E)
 */
#include <cstdint>
#include <cstdlib>
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
        s += static_cast<char>(0x80 | (v & 0x3F));
    } else {
        s += static_cast<char>(0xF0 | (v >> 18));
        s += static_cast<char>(0x80 | ((v >> 12) & 0x3F));
        s += static_cast<char>(0x80 | ((v >> 6) & 0x3F));
        s += static_cast<char>(0x80 | (v & 0x3F));
    }
    return s;
}

int g_pass = 0;
int g_fail = 0;

void check(bool ok, const std::string &what) {
    if (ok) {
        ++g_pass;
        FCITX_INFO() << "✓ " << what;
    } else {
        ++g_fail;
        FCITX_INFO() << "✗ " << what;
    }
}

} // namespace

int main() {
    // 官方测试设施：显式注入 addon/数据目录（含 testing/testfrontend 配置）
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
    char arg2[] = "--enable=langya,testfrontend,punctuation";
    char *argv[] = {arg0, arg1, arg2};
    Instance instance(FCITX_ARRAY_SIZE(argv), argv);
    instance.addonManager().registerDefaultLoader(nullptr);

    instance.eventDispatcher().schedule([&instance]() {
        // 唯一输入法 = 琅琊（组配置须在事件循环启动后才能读写）
        auto &imm = instance.inputMethodManager();
        auto group = imm.currentGroup();
        group.inputMethodList().clear();
        group.inputMethodList().emplace_back("langya");
        group.setDefaultInputMethod("langya");
        imm.setGroup(std::move(group));

        auto *tf = instance.addonManager().addon("testfrontend");
        check(tf != nullptr, "testfrontend 加载");
        auto *langya = instance.addonManager().addon("langya");
        check(langya != nullptr, "langya 引擎加载");
        if (!tf || !langya) {
            instance.exit(1);
            return;
        }
        auto uuid =
            tf->call<ITestFrontend::createInputContext>("langya-test");
        auto *ic = instance.inputContextManager().findByUUID(uuid);
        check(ic != nullptr, "输入上下文创建");
        ic->focusIn();  // 无焦点的上下文不接收按键
        check(instance.inputMethod(ic) == "langya", "当前输入法为琅琊");

        auto key = [&](const std::string &k) {
            tf->call<ITestFrontend::sendKeyEvent>(uuid, Key(k), false);
        };
        // Key("Ctrl+Shift+S") 的字符串解析会丢 Ctrl，须显式构造状态
        auto toggleMode = [&]() {
            tf->call<ITestFrontend::sendKeyEvent>(
                uuid, Key(FcitxKey_s, KeyState::Ctrl_Shift), false);
        };

        // 1) 小篆模式默认：wo + 空格 → 我 U+3F57E
        tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3F57E));
        key("w"); key("o"); key("space");
        check(true, "wo+空格 上屏小篆「我」(U+3F57E)");

        // 2) Ctrl+Shift+S 切楷化：wo + 空格 → 我
        toggleMode();
        tf->call<ITestFrontend::pushCommitExpectation>("我");
        key("w"); key("o"); key("space");
        check(true, "切楷化后 wo+空格 上屏「我」");

        // 切回小篆（模式已持久化到配置——重新激活后应保持）
        toggleMode();
        // 7) 持久化回归：重新激活引擎（模拟切换走再切回），模式须保持小篆
        {
            // 触发 activate：重新 focus
            tf->call<ITestFrontend::destroyInputContext>(uuid);
            uuid = tf->call<ITestFrontend::createInputContext>("langya-test2");
            auto *ic2 = instance.inputContextManager().findByUUID(uuid);
            ic2->focusIn();
            tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3F57E));
            key("w"); key("o"); key("space");
            check(true, "重新激活后模式保持小篆（wo → 𿕾）");
        }

        // 3) 词组：zhongguo + 空格 → 中(U+3D119) 國(U+3E1D3)
        tf->call<ITestFrontend::pushCommitExpectation>(
            cp(0x3D119) + cp(0x3E1D3));
        for (char c : std::string("zhongguo")) {
            key(std::string(1, c));
        }
        key("space");
        check(true, "zhongguo+空格 上屏「中國」小篆");

        // 4) 数字选词：ni + 2 → 拟（libime 真实第二候选，U+3F3B2）
        tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3F3B2));
        key("n"); key("i"); key("2");
        check(true, "ni+2 上屏「拟」小篆");

        // 5) 软键盘状态回归：带 NumLock 的 w/o 仍组字（Android 虚拟
        //    键盘事件常带键盘锁状态，旧判定会漏拦致字母直出）
        tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3F57E));
        tf->call<ITestFrontend::sendKeyEvent>(
            uuid, Key(FcitxKey_w, KeyStates(KeyState::NumLock)), false);
        tf->call<ITestFrontend::sendKeyEvent>(
            uuid, Key(FcitxKey_o, KeyStates(KeyState::NumLock)), false);
        key("space");
        check(true, "NumLock 状态下 wo+空格 仍上屏小篆「我」");

        // 8) 翻页选词：ni + PageDown 翻页 + 数字选第二页第 1 项
        //    （ni 第 6 候选「呢」，說文未收回退原字）
        tf->call<ITestFrontend::pushCommitExpectation>("呢");
        key("n"); key("i");
        key("Page_Down");
        key("1");
        check(true, "ni+PageDown+1 翻页选词上屏「呢」");
        // 8b) 翻页保持高亮位：ni+Right(高亮第2)+PageDown(应仍指
        //     第2)+space（选第二页第2项＝第7候选，非第一页的「拟」）
        tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3E864));
        {
            key("n"); key("i");
            key("Right");            // 高亮 → 第 2 项
            key("Page_Down");        // 翻页，SameAsLast 保持第 2 项
            key("space");            // 选第二页第 2 项（𾡤=尼，libime 第 7 候选）
        }
        check(true, "ni+Right+PageDown+空格 翻页保持高亮位并选所指");

        // 9) 方向键浏览：zhongguo + Right 移高亮 + 空格确认所指
        //    （第 2 候选「中过」）
        tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3D119) + cp(0x3D4E7));
        for (char c : std::string("zhongguo")) key(std::string(1, c));
        key("Right");
        key("space");
        check(true, "zhongguo+Right+空格 上屏高亮候选");

        // 6) 退格改键：woh + 退格 + 空格 → 我 U+3F57E
        tf->call<ITestFrontend::pushCommitExpectation>(cp(0x3F57E));
        key("w"); key("o"); key("h"); key("BackSpace"); key("space");
        check(true, "woh+退格+空格 上屏小篆「我」");

        tf->call<ITestFrontend::destroyInputContext>(uuid);
        instance.exit(g_fail == 0 ? 0 : 1);
    });

    instance.exec();
    FCITX_INFO() << "通过 " << g_pass << " 项，失败 " << g_fail << " 项";
    return g_fail == 0 ? 0 : 1;
}
