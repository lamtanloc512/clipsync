# ClipSync

[English](README.md) · **Tiếng Việt**

Chia sẻ clipboard giữa Mac và điện thoại qua Wi‑Fi trong nhà, giống tính năng đồng bộ clipboard của KDE Connect. Điện thoại không cần cài app.

- **Mac → điện thoại:** copy trên Mac là nội dung hiện gần như ngay lập tức trên điện thoại.
- **Điện thoại → Mac:** gửi chữ hoặc ảnh từ điện thoại, rồi dán trên Mac bằng ⌘V.
- **Chạy được trên Android và iPhone** qua trình duyệt. Có thể dùng thêm iOS Shortcuts / Android HTTP Shortcuts để gửi bằng một chạm.
- **Riêng tư:** dữ liệu chỉ đi trong mạng nội bộ. Không tài khoản, không cloud, không theo dõi.
- **Pair an toàn:** quét mã QR, xác nhận mã trùng khớp trên Mac. Kết nối được mã hoá bằng HTTPS.
- **Gọn nhẹ:** chỉ là một app nhỏ trên thanh menu, không dùng thư viện bên thứ ba.

## Yêu cầu

- Mac chạy **macOS 13 Ventura trở lên** (Apple Silicon hoặc Intel)
- Điện thoại Android hoặc iPhone có trình duyệt đời mới
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
2. Quét mã QR bằng camera điện thoại.
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

### Trên điện thoại (trang web)

- **Mac clipboard:** hiện nội dung bạn copy gần nhất trên Mac. Bấm **Copy to phone** để chép vào điện thoại (chữ hoặc ảnh).
- **Send to Mac:** gõ hoặc dán chữ rồi bấm **Send to Mac**. **Paste & send clipboard** gửi clipboard của điện thoại chỉ bằng một chạm, còn **Photo** dùng để gửi ảnh.

### Trên Mac (thanh menu)

| Mục | Chức năng |
|---|---|
| **Pair a Phone** | Hiện mã QR để pair |
| **Send Certificate via AirDrop** | Gửi chứng chỉ sang iPhone |
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
| Firewall của macOS chặn kết nối | **System Settings → Network → Firewall → Options** → cho phép ClipSync. |
| Mật khẩu không hiện trên điện thoại | Đây là chủ ý. Nội dung copy từ trình quản lý mật khẩu không bao giờ được chia sẻ. |

## Bảo mật và quyền riêng tư

- Dữ liệu không rời khỏi mạng nội bộ của bạn. ClipSync không có server, không tài khoản, không thu thập dữ liệu.
- Kết nối dùng HTTPS với chứng chỉ tạo ngay trên Mac. Chứng chỉ chỉ hợp lệ với địa chỉ nội bộ nên không thể dùng để giả mạo website thật.
- Muốn pair phải có mã QR (chỉ hiện trên màn hình Mac của bạn) và phải bấm **Accept**.
- Mỗi điện thoại có khoá riêng, có thể thu hồi bất cứ lúc nào trong **Paired Devices**.
- **Điện thoại đã pair đọc được mọi thứ bạn copy và có thể thay đổi clipboard của Mac.** Chỉ pair thiết bị của chính bạn, và unpair ngay nếu mất điện thoại.

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
