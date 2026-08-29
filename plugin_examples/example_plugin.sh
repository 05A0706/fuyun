#!/system/bin/sh
#
# example_plugin.sh - fuyun 内置示例插件 (默认停用, 仅供演示插件接口)
#
# 启用方式: WebUI「管理 → 插件」卡片一键启用, 或终端:
#   mv /data/adb/uperf/plugins/example_plugin.sh.disabled \
#      /data/adb/uperf/plugins/example_plugin.sh
#
# 插件接口约定:
#   - 由模块以独立子进程调用: sh <plugin>.sh <stage>
#   - stage: apply(配置应用后) / clear(配置清除后) / boot(开机服务就绪后)
#   - 环境变量:
#       FUYUN_STAGE       当前阶段
#       FUYUN_SOC         当前 SoC 配置名 (sdm8+ / sdm8g2 / sdm8g3 / sdm8e / sdm8e5 / unsupported)
#       FUYUN_MODULE_DIR  模块安装目录
#       FUYUN_USER_PATH   用户配置目录 (/sdcard/Android/yc/uperf)
#       FUYUN_PLUGIN_DIR  插件目录 (/data/adb/uperf/plugins)
#   - stdout/stderr 会追加到 /sdcard/Android/yc/uperf/plugin.log
#   - 插件失败不影响模块主功能
#
# 本示例只写日志, 不做任何实际改动, 可放心启用测试。

stage="${1:-unknown}"

# 在插件日志中打印一行, 便于确认插件确实被调用
echo "[example] stage=$stage FUYUN_SOC=$FUYUN_SOC MODULE_DIR=$FUYUN_MODULE_DIR"

# 演示: 按阶段打印不同提示 (可在 plugin.log 中查看)
case "$stage" in
    boot)
        echo "[example] boot 阶段: 开机服务就绪, 可在此做一次性初始化"
        ;;
    apply)
        echo "[example] apply 阶段: 调度配置已应用"
        ;;
    clear)
        echo "[example] clear 阶段: 调度配置已清除"
        ;;
esac

# 返回 0 = 成功; 非 0 只会记录日志, 不影响模块
exit 0
