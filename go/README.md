# Go 语言笔记

Go 并发编程 Channel 关闭模式总结。

## 文件说明

| 文件 | 说明 |
|---|---|
| [graceful-close-channel.md](graceful-close-channel.md) | Go Channel 优雅关闭的四种模式：1:1（单生产者关闭 channel）、1:N（生产者关闭 channel，多消费者 range 接收）、N:1（引入 stopCh 信号 channel 由接收方关闭）、N:M（moderator 协调 goroutine 通过 toStop channel 通知关闭 stopCh） |
