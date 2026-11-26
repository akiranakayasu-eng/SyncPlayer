v0.3.5: 設定が「素材・レイヤー・Screen」のどれに効くかを整理した版です。右のタブは Properties（上に選んだレイヤー、下に Screen）、Setup、Guide。エッジブレンドは Screen の設定になり、Crop に縁のぼかし（Feather）を足しました。素材のプレビュー再生、選んだレイヤーの枠（B）、窓の題とアプリの名前に版も入りました。同期でつなぐ Mac は全台を同じ版にそろえてください。

**前の版から上げるときの注意**
- **位置・大きさ・回転は、レイヤーごと（四隅・曲面ごと）動かす作りになりました**（After Effects と同じ）。前の版でこれらを変えていたショーは、開くと見え方が変わります。開いたときに知らせが出るので、Properties の Transform で合わせ直してください。エッジブレンドは前の値が Screen に移ります。
- アプリの名前が `SyncPlayer 0.3.5.app` のように版入りになりました。前の版の `SyncPlayer.app` はごみ箱へ入れてください（残すと古い方を開いてしまいます）。「ログインしたら SyncPlayer を開く」を入れていた Mac は、新しい版を 1 度開くと入れ直します。念のため、Setup の This Mac でスイッチが入っているか見てください。

**サンプル（映像と設定）**: アプリとは別に `SyncPlayer-0.3.5-samples.zip` を置きました。音入りのサンプル映像 20 本と、ダブルクリックで開けるショー 7 つ、`使い方.txt` が入っています。フォルダごと展開して使ってください。

macOS 13 以降、Apple シリコンと Intel の両方で動く SyncPlayer です（展開すると `SyncPlayer 0.3.5.app`）。

**初めて開くとき**: この .app は Apple の公証を受けていないので、最初の 1 回だけ macOS に止められます。開き方は README の「ダウンロードして使う」を見てください。

使い方・キー・既知の制限は [README](https://github.com/akiranakayasu-eng/sync-player#readme) に、この版と前の版の違いは [版の履歴（CHANGELOG）](https://github.com/akiranakayasu-eng/sync-player/blob/main/CHANGELOG.md) にあります。
