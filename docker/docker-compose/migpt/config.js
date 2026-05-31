/**
 * @type {import('@mi-gpt/next').MiGPTConfig}
 */
export default {
    speaker: {
        /**
         * 小爱音箱在米家中设置的名称
         *
         * 如果提示找不到设备，请打开 debug 选项获取设备真实的 name、miotDID 或 mac 地址填入
         */
        did: 'Xiaomi 智能音箱 Pro',
        /**
         * 小米 ID（一串数字）
         *
         * 注意：不是手机号或邮箱，请在小米账号「个人信息」-「小米 ID」查看
         */
        userId: '2279096540',
        /**
         * 小米账号登录密码
         *
         * 如果提示登录失败，请使用 passToken 登录
         */
        password: 'yuxinmin1258+',
        /**
         * （可选）小米账号 passToken
         *
         * 获取教程：https://github.com/idootop/migpt-next/issues/4
         */
        passToken: 'V1:DXmurwq2/R1BHTELu6obCSkmrZhjN8xSQs3QrcFMfEntE0OhJqDRUQkEkx3NopManETJ5S4Ed5aZiIjyqNgDcYP+heyyj+58oLX+MGf94/HTwQNH5uZit4B5iBlONlJ9PqFhyuUtHJ3qZKC7k8UqQeKi/WQIyFTUcsEr2julctQrmf3cyDawi3AxDokLrl8LuHqWLmIDj3R9YHdhcyK7xeyNs14eHqyF8dezrvX0zb9xtBu1OPrbHEVGNqw1umbIfC9gz1Md0SjFb0mmV4JRJ0R44rfWZe7J/BxC5OQj7u1cCieZJtV579YQ+plI02tzEQ0Or34JhteMtvTz9Ab3Gw==',
    },
    openai: {
        /**
         * 你的大模型服务提供商的接口地址
         *
         * 支持兼容 OpenAI 接口的大模型服务，比如：DeepSeek V3 等
         *
         * 注意：一般以 /v1 结尾，不包含 /chat/completions 部分
         * - ✅ https://api.openai.com/v1
         * - ❌ https://api.openai.com/v1/（最后多了一个 /
         * - ❌ https://api.openai.com/v1/chat/completions（不需要加 /chat/completions）
         */
        baseURL: 'http://host.docker.internal:11434/v1',
        /**
         * API 密钥
         */
        apiKey: '',
        /**
         * 模型名称
         */
        model: 'deepseek-r1:14b',
    },
    prompt: {
        /**
         * 系统提示词，如需关闭可设置为：''（空字符串）
         */
        system: '你是一个智能助手，请根据用户的问题给出回答。',
    },
    context: {
        /**
         * 每次对话携带的最大历史消息数（如需关闭可设置为：0）
         */
        historyMaxLength: 10,
    },
    /**
     * 只回答以下关键词开头的消息：
     *
     * - 请问地球为什么是圆的？
     * - 你知道世界上跑的最快的动物是什么吗？
     */
    callAIKeywords: ['请', '你'],
    /**
     * 自定义消息回复
     */
    async onMessage(engine, { text }) {
        if (text === '测试播放文字') {
            return { text: '你好，很高兴认识你！' };
        }

        if (text === '测试播放音乐') {
            return { url: 'https://example.com/hello.mp3' };
        }

        if (text === '测试其他能力') {
            // 打断原来小爱的回复
            await engine.speaker.abortXiaoAI();

            // 播放文字
            await engine.speaker.play({ text: '你好' });

            // 播放音频链接
            await engine.speaker.play({ url: 'https://example.com/hello.mp3' });

            // 调用 MiNA 的能力
            await engine.MiNA.setVolume(50); // 音量调到 50%

            // 调用 MioT 的能力（请到 https://home.miot-spec.com 查询指令列表）
            await engine.MiOT.doAction(2, 1, 50); // 音量调到 50%

            // 告诉 MiGPT 已经处理过这条消息了，不再使用默认的 AI 回复
            return { handled: true };
        }
    },
};
