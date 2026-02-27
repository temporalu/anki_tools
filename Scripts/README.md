### 使用方式

- 默认：前 10 行、2 并发
  - bash /Users/pengyu/Documents/Github\ Project/anki_tools/Scripts/batch_add_anki_words.sh
- 指定范围与并发：
  - bash /Users/pengyu/Documents/Github\ Project/anki_tools/Scripts/batch_add_anki_words.sh --start 1 --end 100 --jobs 4
- 覆盖牌组/笔记类型/字段：
  - TARGET_DECK=Default NOTE_TYPE=Basic FRONT_FIELD=Front BACK_FIELD=Back SOURCE_FIELD=Source bash ...