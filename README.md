# CC:T Sync Music v3

テーマパークで使われてるような音楽同期システム。
複数のComputerに繋いだSpeakerで、同じ曲をズレずに同時再生する。
シングルプレイでもサーバーでも使える。

## 必要なもの

### Minecraft Mod
- [CC: Tweaked](https://tweaked.cc/) (v1.100.0以上)

### ブロック

| アイテム | 用途 |
|---|---|
| Advanced Computer | Master用 (1台) |
| Normal Computer | Slave用 (各スピーカーに1台) |
| Speaker | Slaveに接続 (Masterは不要) |
| Wireless Modem | 各Computerに1個 |

SpeakerはComputerの横に直接置いてOK。Wireless Modemも右クリックで取り付けるだけ。

## セットアップ

### 1. Master

Advanced Computerを右クリックして開く。

```
wget run https://raw.githubusercontent.com/motchii709/cct-sync-music/master/master.lua
```

`master` と打って実行。初回起動時にグループ名を入力する。

```
Group name: テーマパーク
```

グループ名は `.master_config` に保存される。

### 2. Slave

各Normal Computerを右クリックして開く。

```
wget run https://raw.githubusercontent.com/motchii709/cct-sync-music/master/slave.lua
```

`slave` と打って実行。初回起動時にグループ名とコンピュータ名を入力する。

```
Group name: テーマパーク
Computer name: 入口
```

設定は `.slave_config` に保存される。2回目以降は自動で読み込まれる。
**Masterと同じグループ名を入力すると自動接続される。**

### 3. 曲を選ぶ

Masterの画面で「Playlist」タブをクリック → YouTubeのURL貼るかキーワード検索。

### 4. 再生

「Now Playing」タブ → 「Sync All」ボタン。

これで全Slaveに同期コマンドが飛んで、同時に再生開始する。

## TUI

### Master (4タブ)
- **Now Playing**: 曲情報、Play/Stop/Skip、Sync All、ボリューム、キュー
- **Playlist**: YouTube検索、曲追加
- **Slaves**: 接続中のSlave一覧、ステータス、RTT、最終通信時刻
- **Log**: 全Slaveからの詳細なログ (接続、DL、再生、エラー等)

### Slave
- ステータス表示: Group名、接続状態、現在の曲、音量、Master状態
- ログ表示: 最新のログがリアルタイムで表示される

## 同期の仕組み

1. Masterが「この曲を再生」って全Slaveにbroadcast
2. Slave全員がFirebaseから同じ曲をダウンロードしてdiskにキャッシュ
3. Masterが各SlaveとのRTT（遅延）を計測
4. 遅延分を補正した再生開始時刻を送信
5. 全Machineが同じタイミングで再生開始

だいたい100-200msくらいの精度。50m離れたスピーカーだと音速で145msくらいかかるから、それも考慮に入れてる。

## 通信プロトコル

rednet（Wireless Modem）を使ってる。Protocol名は `park_music_v3`。

| コマンド | 送信元 | 内容 |
|---|---|---|
| master_hello | Master→全Slave | Master起動通知 |
| welcome | Master→Slave | グループ参加許可 |
| download | Master→Slave | 曲をDLしてキャッシュ |
| ping | Master→Slave | RTT計測用 |
| play_at | Master→Slave | 指定時刻に再生開始 |
| stop | Master→Slave | 再生停止 |
| volume | Master→Slave | 音量変更 |
| heartbeat | 双方向 | 生存確認 |
| hello | Slave→Master | 起動時参加通知 |
| ready | Slave→Master | DL完了通知 |
| pong | Slave→Master | RTT応答 |
| track_end | Slave→Master | 曲終了通知 |
| play_started | Slave→Master | 再生開始確認 |
| play_stopped | Slave→Master | 停止確認 |

## 注意点

- Wireless Modemの通信範囲に収まるように配置してね
- Firebase APIのURLが変わった場合は `master.lua` と `slave.lua` の `API_BASE_URL` を書き換える
- キャッシュは各Machineの `cache/` フォルダに入る
- Masterの設定は `.master_config` に保存される
- Slaveの設定は `.slave_config` に保存される

## ライセンス

MIT License
