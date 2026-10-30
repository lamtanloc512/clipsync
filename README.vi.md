# ClipSync

[English](README.md) · **Tiếng Việt**

Chia sẻ clipboard giữa Mac và điện thoại qua Wi‑Fi trong nhà, giống tính năng đồng bộ clipboard của KDE Connect. Điện thoại không cần cài app.

- **Tự động đồng bộ hai chiều:** copy trên Mac là có ngay trong clipboard điện thoại; copy trên điện thoại là có trên Mac, khi ClipSync đang mở trên điện thoại.
- **Gửi file và video, dung lượng bao nhiêu cũng được:** từ điện thoại vào thẳng thư mục Downloads của Mac (và vào clipboard, sẵn sàng ⌘V). Copy một file trong Finder là điện thoại tải về được.
- **Chạy được trên Android và iPhone** qua trình duyệt. Có thể dùng thêm iOS Shortcuts / Android HTTP Shortcuts để gửi bằng một chạm.
- **Riêng tư:** dữ liệu chỉ đi trong mạng nội bộ. Không tài khoản, không cloud, không theo dõi.
- **Pair an toàn:** quét mã QR, xác nhận mã trùng khớp trên Mac. Kết nối được mã hoá bằng HTTPS.
- **Không cần gõ địa chỉ IP:** trong mạng nội bộ, Mac được gọi bằng tên `clipsync.local`.
- **Gọn nhẹ:** chỉ là một app nhỏ trên thanh menu, không dùng thư viện bên thứ ba.

## Yêu cầu

- Mac chạy **macOS 11 Big Sur trở lên** (Apple Silicon hoặc Intel)
- Điện thoại **Android** có Chrome 111 trở lên (Android 8+), hoặc **iPhone/iPad chạy iOS 16.4** trở lên
- Hai thiết bị dùng **chung một mạng Wi‑Fi** (hoặc Mac kết nối vào hotspot của điện thoại)

## Tải về và cài đặt

1. Tải **`ClipSync-macOS.zip`** ở [bản phát hành mới nhất](https://github.com/lamtanloc512/clipsync/releases/latest).
2. Giải nén, rồi kéo **ClipSync.app** vào thư mục **Applications**.
3. Mở app. ClipSync chưa được Apple notarize nên lần đầu macOS sẽ chặn. Có 2 cách mở:
   - Chuột phải vào **ClipSync.app** → **Open** → **Open**, hoặc
   - Chạy `xattr -dr com.apple.quarantine /Applications/ClipSync.app` trong Terminal.
4. Khi macOS hỏi *"Allow incoming network connections?"*, chọn **Allow**.

ClipSync hiện thành biểu tượng clipboard trên thanh menu. App không có biểu tượng trên Dock.

> **Kiểm tra file tải về (không bắt buộc).** Mỗi bản phát hành có kèm file `SHA256SUMS.txt`. Chạy `shasum -a 256 ClipSync-macOS.zip` rồi so kết quả với giá trị trong file đó.

## Pair điện thoại

1. Bấm biểu tượng trên thanh menu → **Pair a Phone**. Một cửa sổ có mã QR sẽ mở ra.
2. Quét mã QR bằng camera điện thoại. Trang `https://clipsync.local:8765` sẽ mở ra.
   - Nếu trang không mở được (một số máy Android không mở được địa chỉ `.local`), bấm **"Use the IP address instead"** trong cửa sổ QR rồi quét lại.
3. Lần đầu, trình duyệt sẽ cảnh báo kết nối không riêng tư. Điều này là bình thường, vì Mac dùng chứng chỉ do chính nó tạo ra.
   - Android (Chrome): **Advanced** → **Proceed**
   - iPhone (Safari): **Show Details** → **visit this website** → **Visit Website**
4. Đặt tên cho điện thoại rồi bấm **Pair**. Một mã 4 số sẽ hiện ra.
5. Mac hiện thông báo *"… wants to pair"* kèm một mã. Nếu hai mã trùng nhau, bấm **Accept**.
6. Thêm trang vào màn hình chính để mở như một app:
   - Chrome: menu → **Add to Home screen**
   - Safari: **Share** → **Add to Home Screen**

Mỗi mã QR chỉ dùng được một lần và hết hạn sau 10 phút. Muốn pair thêm máy khác, mở lại **Pair a Phone**.

### Cài chứng chỉ (khuyến nghị)

Cài chứng chỉ của Mac lên điện thoại để không còn cảnh báo trên trình duyệt. Bước này cũng bắt buộc nếu muốn dùng Shortcuts / HTTP Shortcuts. Trên trang web, mở **Settings** và làm theo hướng dẫn.

**Android**
1. Mẹo: làm bước này khi Mac đang kết nối vào **hotspot** của chính điện thoại. Mạng đó chỉ có hai thiết bị của bạn nên không ai chen vào được.
2. Tải `ca.crt` trong mục **Settings** của trang.
3. Vào **Cài đặt → Bảo mật → Mã hoá và thông tin xác thực → Cài đặt chứng chỉ → Chứng chỉ CA**.
4. Kiểm tra: **Thông tin xác thực đáng tin cậy → Người dùng → ClipSync**. Fingerprint SHA‑256 phải **bắt đầu và kết thúc** giống các ký tự hiện ở cuối cửa sổ QR trên Mac.

**iPhone / iPad**
1. Dễ và an toàn nhất: trên Mac, chọn **Send Certificate via AirDrop…** trong menu rồi gửi sang iPhone. Hoặc tải profile trong mục **Settings** của trang.
2. Vào **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị → ClipSync → Cài đặt**.
3. Vào **Cài đặt → Cài đặt chung → Giới thiệu → Cài đặt tin cậy chứng nhận**, bật **ClipSync**.

Chứng chỉ này chỉ hợp lệ với địa chỉ trong mạng nội bộ (`192.168.x.x`, `10.x.x.x`, `*.local`, …), nên không thể dùng để giả mạo website thật.

## Sử dụng

### Trên điện thoại

Mở ClipSync từ màn hình chính và để nó mở. Hai công tắc trong **Auto sync** được bật sẵn:

- **Copy from Mac automatically:** nội dung copy trên Mac sẽ vào clipboard điện thoại.
- **Send this phone's clipboard automatically:** nội dung copy trên điện thoại sẽ được gửi sang Mac. Lần đầu, bấm **Allow** để ClipSync được đọc clipboard.

"Tự động" đến mức nào tuỳ vào điện thoại, vì trình duyệt bảo vệ clipboard:

| | Android (Chrome) | iPhone (Safari) |
|---|---|---|
| Mac → điện thoại | Copy ngay khi ClipSync đang hiện trên màn hình | Copy ở lần chạm kế tiếp bất kỳ đâu trong ClipSync |
| Điện thoại → Mac | Gửi khi mở ClipSync và mỗi 2 giây khi đang mở | Bấm **Send clipboard to Mac** (iOS hỏi xác nhận Paste) |
| Khi chạy nền | Bắt kịp ngay khi mở lại ClipSync | Như Android |

Không trang web nào chạy nền được, nên điện thoại đồng bộ mỗi khi ClipSync đang mở.

### Gửi file và video

- **Điện thoại → Mac:** bấm **Send files to Mac**, chọn ảnh, video hoặc file bất kỳ; mỗi file có thanh tiến trình. File được lưu vào thư mục **Downloads** của Mac, đưa vào clipboard Mac (⌘V để dán file vào Finder, Mail, Slack…) và có thông báo — bấm vào để mở file trong Finder. File được ghi thẳng xuống đĩa nên chỉ giới hạn bởi dung lượng trống của Mac (mặc định tối đa 20 GB mỗi file).
- **Mac → điện thoại:** copy file trong Finder (⌘C), hoặc chọn **Send File to Phones…** trên menu. Điện thoại hiện file trong mục **Latest** kèm nút **Download**.
- Giữ ClipSync mở trên điện thoại cho đến khi gửi xong; trình duyệt tạm dừng trang khi chạy nền. Mục **Latest** hiện nội dung đồng bộ gần nhất. **Settings** (⚙) có gửi thủ công (chữ hoặc ảnh), cài chứng chỉ, token cho Shortcuts và **Unpair**.

### Trên Mac (thanh menu)

| Mục | Chức năng |
|---|---|
| **Pair a Phone** | Hiện mã QR để pair |
| **Send Certificate via AirDrop** | Gửi chứng chỉ sang iPhone |
| **Send File to Phones…** | Gửi một file để điện thoại tải về (giống copy file trong Finder) |
| **Paired Devices** | Danh sách điện thoại đã pair; chọn một máy → **Unpair** để gỡ |
| **Recent** | 20 mục copy gần nhất; bấm vào để copy lại |
| **Launch at Login** | Tự chạy ClipSync khi đăng nhập |

### Phím tắt một chạm (không bắt buộc)

Cần cài chứng chỉ trước. Sau đó vào trang web → **Settings → Show token** để lấy token. Thay `YOUR-MAC.local` bằng địa chỉ hiện trên thanh menu.

**iOS Shortcuts: "Gửi clipboard sang Mac"**
1. **Get Clipboard**
2. **Get Contents of URL**
   - URL: `https://YOUR-MAC.local:8765/api/clipboard`
   - Method: **POST**
   - Headers: `X-Token` = *token của bạn*
   - Request Body: **File** → *Clipboard*

**iOS Shortcuts: "Lấy clipboard từ Mac"**
1. **Get Contents of URL**: `https://YOUR-MAC.local:8765/api/clipboard/raw`, header `X-Token` = *token của bạn*
2. **Copy to Clipboard**

Mẹo: gán shortcut vào **Back Tap** (Cài đặt → Trợ năng → Cảm ứng → Chạm vào mặt sau) để gõ 2 lần vào lưng máy là chạy.

**Android:** tạo các request tương tự bằng [HTTP Shortcuts](https://http-shortcuts.rmy.ch/) hoặc Tasker.

## Xử lý sự cố

| Vấn đề | Cách xử lý |
|---|---|
| Link trong QR không mở được | Kiểm tra hai thiết bị có cùng Wi‑Fi không. Bấm **"Use the IP address instead"** trong cửa sổ QR. |
| Điện thoại báo "Mac not reachable" | Kiểm tra ClipSync có đang chạy và Mac có đang ngủ không. Một số Wi‑Fi công cộng hoặc Wi‑Fi khách chặn các thiết bị nói chuyện với nhau; khi đó hãy dùng hotspot của điện thoại. |
| "This QR code expired or was already used" | Mở lại **Pair a Phone** trên Mac và quét mã mới. |
| "This device is no longer paired" | Điện thoại đã bị unpair trên Mac. Pair lại. |
| Điện thoại không tự gửi sang Mac | Bấm **Allow** trong Auto sync. Nếu trước đó đã chặn, vào cài đặt trang của Chrome cho `clipsync.local` và cho phép **Clipboard**. |
| "New from your Mac — tap to copy" | Trình duyệt chỉ cho ghi clipboard khi ClipSync đang hiện trên màn hình (Android) hoặc khi bạn chạm (iPhone). Chạm vào bất kỳ đâu. |
| Firewall của macOS chặn kết nối | **System Settings → Network → Firewall → Options** → cho phép ClipSync. |
| Mật khẩu không hiện trên điện thoại | Đây là chủ ý. Nội dung copy từ trình quản lý mật khẩu không bao giờ được chia sẻ. |

## Bảo mật và quyền riêng tư

- Dữ liệu không rời khỏi mạng nội bộ của bạn. ClipSync không có server, không tài khoản, không thu thập dữ liệu.
- Kết nối dùng HTTPS với chứng chỉ tạo ngay trên Mac. Chứng chỉ chỉ hợp lệ với địa chỉ nội bộ nên không thể dùng để giả mạo website thật.
- Muốn pair phải có mã QR (chỉ hiện trên màn hình Mac của bạn) và phải bấm **Accept**.
- Mỗi điện thoại có khoá riêng, có thể thu hồi bất cứ lúc nào trong **Paired Devices**.
- **Điện thoại đã pair đọc được mọi thứ bạn copy và có thể thay đổi clipboard của Mac.** Chỉ pair thiết bị của chính bạn, và unpair ngay nếu mất điện thoại.
- File bạn copy trong Finder (hoặc gửi từ menu) có thể được điện thoại đã pair tải về khi nó đang nằm trong clipboard. File nhận từ điện thoại được đánh dấu là tải từ internet, nên macOS kiểm tra như mọi file tải về khác.
- Khi bật **Send this phone's clipboard automatically**, mọi thứ bạn copy trên điện thoại lúc ClipSync đang mở (kể cả mật khẩu) sẽ được gửi sang Mac. Tắt công tắc này nếu không muốn.
- Trong mạng, Mac xuất hiện với tên `clipsync.local`; mã QR và trình duyệt không hiện IP hay tên Mac của bạn.

Mô hình mối đe doạ đầy đủ nằm trong [SECURITY.md](SECURITY.md) (tiếng Anh). Nếu phát hiện lỗ hổng, vui lòng báo cáo riêng theo hướng dẫn trong file đó.

## Tự build từ mã nguồn

Cần Xcode hoặc Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/lamtanloc512/clipsync.git
cd clipsync
./build-app.sh --install
```

Kiến trúc, API và ghi chú phát triển nằm trong [CONTRIBUTING.md](CONTRIBUTING.md) (tiếng Anh).

## Đóng góp

Mọi báo lỗi, ý tưởng và pull request đều được hoan nghênh! Vui lòng đọc [CONTRIBUTING.md](CONTRIBUTING.md) và tuân thủ [Quy tắc ứng xử](CODE_OF_CONDUCT.md).

## Giấy phép

ClipSync là phần mềm tự do, phát hành theo [Giấy phép Công cộng GNU phiên bản 3.0 (GPL-3.0)](LICENSE).
