并发执行脚本

```
#!/bin/bash
for ((i=10;i<=310;i++));do
while read line
do
{
  ffmpeg -re -stream_loop -1 -i $line -vcodec copy -codec copy -f rtsp rtsp://127.0.0.1:554/video$i
} &
done< 1.txt
 

done
wait
```

