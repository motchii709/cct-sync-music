# CC:T Sync Music

テーマパークで使われてるような音楽同期システム。
複数のComputerに繋いだSpeakerで、同じ曲をズレずに同時再生する。

## 必要なもの

### Minecraft Mod
- [CC: Tweaked](https://tweaked.cc/) (v1.100.0以上)

### ブロック

| アイテム | 用途 |
|---|---|
| Advanced Computer | Master用 (1台) |
| Normal Computer | Slave用 (各ゾーンに1台) |
| Speaker | 各Computerに最低1個 |
| Wireless Modem | 各Computerに1個 |

SpeakerはComputerの横に直接置いてOK。Wireless Modemも右クリックで取り付けるだけ。

## 使い方

### 1. Masterセットアップ

Advanced Computerに `master.lua` を入れて `master` を実行。

```
master.lua をAdvanced Computerにドラッグ&ドロップ
> master
```

### 2. Slaveセットアップ

各Normal Computerに `slave.lua` を入れて `slave` を実行。

初回起動時にゾーン名を聞かれる。入力すると `.slave_config` に保存されるから、再起動しても毎回入力しなくていい。

```
> slave
Zone name: 入口
```

2回目以降は自動で読み込まれる。

### 3. 曲を選ぶ

Masterの画面で「Playlist」タブをクリック → YouTubeのURL貼るかキーワード検索。

### 4. 再生

「Now Playing」タブ → 「Sync All」ボタン。

これで全Slaveに同期コマンドが飛んで、同時に再生開始する。

## 同期の仕組み

1. Masterが「この曲を再生」って全Slaveにbroadcast
2. Slave全員がFirebaseから同じ曲をダウンロードしてdiskにキャッシュ
3. Masterが各SlaveとのRTT（遅延）を計測
4. 遅延分を補正した再生開始時刻を送信
5. 全Machineが同じタイミングで再生開始

だいたい100-200msくらいの精度。50m離れたスピーカーだと音速で145msくらいかかるから、それも考慮に入れてる。

## スケジュール機能

Scheduleタブで時間帯ごとにプレイリストを設定できる。

```
09:00-12:00  Morning
12:00-15:00  Afternoon
15:00-18:00  Evening
18:00-21:00  Night
```

MCの内時刻（`os.time()`）を見て自動で切り替わる。

## 通信プロトコル

rednet（Wireless Modem）を使ってる。Protocol名は `park_music`。

| コマンド | 送信元 | 内容 |
|---|---|---|
| download | Master→Slave | 曲をDLしてキャッシュ |
| ping | Master→Slave | RTT計測用 |
| play_at | Master→Slave | 指定時刻に再生開始 |
| stop | Master→Slave | 再生停止 |
| volume | Master→Slave | 音量変更 |
| ready | Slave→Master | DL完了通知 |
| pong | Slave→Master | RTT応答 |
| hello | Slave→Master | 起動時参加通知 |

## 注意点

- Wireless Modemの通信範囲に収まるように配置してね
- Firebase APIのURLが変わった場合は `master.lua` と `slave.lua` の `API_BASE_URL` を書き換える
- キャッシュは各Machineの `cache/` フォルダに入る
- Slaveの設定は `.slave_config` に保存される

## ライセンス

MIT License
