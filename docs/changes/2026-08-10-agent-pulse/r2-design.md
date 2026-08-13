# macOS 剪贴板图片上传 Cloudflare R2 安全设计

## 1. 范围与结论

本文只描述安全探测结果和客户端设计，不修改应用源码、环境文件或 R2 配置。探测仅解析形如 `~/.config/agent-pulse/r2.env` 的配置文件变量名并判断是否定义、是否非空；未读取、记录、验证或回显任何配置值。

推荐按使用场景分层：

1. **可分发应用（首选）**：客户端不持有长期 R2 密钥，通过受控服务获取一次性、短时效、限定对象键和 `Content-Type` 的预签名 `PUT` URL。
2. **仅本机、单用户可信环境（可接受的第一阶段）**：一次性从现有 env 导入 macOS Keychain，运行时仅从 Keychain 取凭证并在内存中完成 S3 SigV4；不得把密钥编译进应用、写入 `UserDefaults` 或复制到新的明文配置。
3. **开发模式**：允许由启动脚本引用现有 env 并通过进程环境注入，但应用不自行搜索或解析固定绝对路径。该模式必须显式开启，且不得用于发布构建。

长期 R2 凭证即使保存在 Keychain，也可能被获得本机执行权限或篡改客户端的攻击者使用，因此 Keychain 不能替代预签名服务的最小权限和短时效边界。

## 2. R2 配置脱敏审计

| 变量名 | 已定义 | 非空 | 必要类别 | 结论 |
|---|---:|---:|---|---|
| `R2_ACCOUNT_ID` | 是 | 是 | Account ID | 齐全 |
| `R2_ENDPOINT` | 是 | 是 | S3 endpoint | 齐全 |
| `R2_ACCESS_KEY_ID` | 是 | 是 | Access Key ID | 齐全；敏感标识，不应记录 |
| `R2_SECRET_ACCESS_KEY` | 是 | 是 | Secret Access Key | 齐全；秘密，不应离开安全存储 |
| `R2_BUCKET` | 是 | 是 | Bucket | 齐全 |
| `R2_PUBLIC_BASE_URL` | 是 | 是 | 公开访问基址 | 齐全 |

上传所需的 endpoint、account ID、access key、secret key、bucket、公开 URL 六类字段均存在且非空。配置采用独立键值字段形态，没有发现单独的 region 或对象前缀字段；R2 SigV4 region 应固定为 `auto`，新对象前缀应成为客户端的非秘密配置。

本次未验证值的格式、endpoint 可达性、凭证有效性、bucket 是否存在、公开域名是否已绑定或权限是否正确，因此“字段齐全”不等于“配置可用”。后续验证不得将请求头、签名、凭证或完整 env 输出到日志。

## 3. 推荐架构

### 3.1 可分发客户端：预签名上传

流程如下：

1. 客户端读取剪贴板图片，规范化为受支持的字节流并计算大小和 SHA-256。
2. 客户端向受控签名服务提交认证信息、扩展名、`Content-Type`、字节数和可选校验摘要；不提交 R2 密钥。
3. 服务端生成新前缀下的唯一对象键，并返回短时效预签名 `PUT` URL、必须发送的请求头、公开 URL 和过期时间。
4. 客户端原样使用返回的 URL 与签名头上传；成功后只展示公开 URL，不记录预签名 URL。
5. 签名服务强制校验前缀、类型、大小、有效期和调用方身份，并进行速率限制与审计。

建议预签名 URL 有效期不超过 5 分钟，只允许一个确定对象键和 `PUT` 方法。若 R2 权限粒度不能限制到“仅写指定前缀且不可删除/列举”，应使用专用上传 bucket；前缀本身只是命名边界，不是权限边界。公开 bucket 中的对象不具备访问控制，随机文件名只能降低被猜中的概率，不能保护敏感图片。上传动作应由用户明确触发，并在上传前提示其结果将公开可访问。

### 3.2 本机客户端：Keychain + 直接 SigV4

仅在单用户可信场景使用。非秘密配置（endpoint、bucket、公开基址、前缀）可由应用配置提供；`R2_ACCESS_KEY_ID` 与 `R2_SECRET_ACCESS_KEY` 分别存入 Keychain Generic Password item。建议：

- 使用应用固定的 Keychain service 名和明确的 account 名，不把秘密放进 item label、命令行参数或错误文本。
- 设置 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，不经 iCloud 同步；按产品需求决定是否要求用户在读取时确认。
- 发布构建禁用 env provider；调试构建中的 provider 只读取当前进程环境，不读取仓库中的固定 `.env` 路径。
- R2 token 仅授权专用 bucket 所需的写能力；若无法限制删除、列举或前缀，使用预签名服务或专用 bucket 缩小爆炸半径。
- 凭证只在签名期间短暂驻留内存；不在日志、埋点、崩溃报告、剪贴板或 UI 中展示。

## 4. 上传协议细节

### 4.1 图片与对象命名

剪贴板读取优先采用原始 PNG 或 JPEG；其他 `NSImage` 表示统一转码为 PNG。MIME 与扩展名必须由实际编码结果共同决定，不能信任文件名：

| 编码 | `Content-Type` | 扩展名 |
|---|---|---|
| PNG | `image/png` | `.png` |
| JPEG | `image/jpeg` | `.jpg` |

默认对象键格式：

```text
clipboard/v1/yyyy/MM/dd/<lowercase-uuid>.<ext>
```

日期使用 UTC，UUID 使用系统安全随机源。前缀作为 `UploadPolicy` 配置，规范化后不得以 `/` 开头，不得包含空段、`.`、`..`、反斜线或控制字符。对象键不得包含用户名、设备名、原文件名、剪贴板文本或内容摘要，避免公开元数据和可关联性。每次上传生成新 UUID，不覆盖既有对象。

客户端在编码后、发请求前检查允许类型和最大字节数；限制值由 `UploadPolicy.maxBytes` 明确定义并由签名服务再次校验。请求只接受 HTTPS endpoint 和 HTTPS 公开基址。

### 4.2 S3 Signature Version 4

直接上传时使用 `PUT`，service 为 `s3`，region 为 `auto`，credential scope 为：

```text
<yyyymmdd>/auto/s3/aws4_request
```

签名器必须：

1. 使用 endpoint、bucket 和逐 path segment RFC 3986 编码后的对象键构造上传 URL，避免重复编码或把 `/` 编码为 `%2F`。
2. 对最终图片字节计算十六进制 SHA-256，写入 `x-amz-content-sha256`。
3. 写入 UTC `x-amz-date`；canonical headers 的名称转小写并按字典序排列，值去除首尾空白且将连续空白折叠为一个空格。规范请求至少签入 `content-type`、`host`、`x-amz-content-sha256`、`x-amz-date`，signed headers 列表必须使用完全相同的顺序。
4. 依次派生 `AWS4` signing key：date → `auto` → `s3` → `aws4_request`，以 HMAC-SHA256 签署 string-to-sign。
5. 将 access key ID、scope、signed headers 和签名写入 `Authorization`；secret key 绝不进入 URL、日志或错误。
6. 使用不可变的同一份 `Data` 计算哈希并发送，防止签名后字节变化。

不要发送 `public-read` ACL；公开访问由 R2 bucket/custom domain 配置决定。公开 URL 使用 `R2_PUBLIC_BASE_URL` 作为基址并追加相同的逐段编码对象键，不能由 S3 endpoint 猜测。若基址已有尾斜线应先规范化，避免双斜线。

### 4.3 成功与错误处理

仅将 HTTP `200...299` 视为上传成功，返回对象键、公开 URL、响应 ETag（若存在）和字节数。ETag 只作为响应元数据，不假设它一定等于 MD5。可选的发布前诊断可以对公开 URL 做 `HEAD`，但 CDN 缓存或传播延迟不能反向触发重复上传。

错误应映射为稳定、可测试且脱敏的类型：

- `clipboardEmpty` / `unsupportedImage` / `imageTooLarge`：不发网络请求，给用户可操作提示。
- `invalidConfiguration`：指出缺少的变量名或非法字段类别，不包含值。
- `credentialUnavailable`：提示解锁 Keychain、重新导入或登录，不回退到硬编码凭证。
- `clockSkew` / `signatureRejected`：不盲目重试，提示校准系统时间或重新获取预签名 URL。
- `unauthorized` / `forbidden`：不重试，提示凭证或权限问题。
- `rateLimited`、网络瞬断和 `5xx`：尊重 `Retry-After`，否则使用带抖动的指数退避；最多重试 `UploadPolicy.maxAttempts`，且只重放未变化的图片字节。
- 其他 `4xx`：默认不重试；保留脱敏状态码和 Cloudflare request ID 便于排障。
- 取消：立即终止网络任务，不包装成失败重试。

日志只允许记录随机 operation ID、对象键的内部散列、字节数、MIME、阶段、HTTP 状态码、耗时和脱敏 request ID。禁止记录 env、Keychain 内容、`Authorization`、预签名 URL、完整公开 URL、响应正文或图片数据。

## 5. 可测试 Swift 接口

以下协议把系统剪贴板、凭证、时间、随机数、签名和网络传输隔离，单元测试无需访问真实 Keychain 或 R2：

```swift
struct UploadPolicy: Sendable {
    let objectPrefix: String
    let maxBytes: Int
    let maxAttempts: Int
    let allowedContentTypes: Set<String>
}

struct EncodedImage: Sendable {
    let data: Data
    let contentType: String
    let fileExtension: String
}

struct R2Configuration: Sendable {
    let endpoint: URL
    let bucket: String
    let publicBaseURL: URL
    let region: String // R2 固定为 "auto"
}

struct R2Credentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
}

struct UploadReceipt: Sendable {
    let objectKey: String
    let publicURL: URL
    let eTag: String?
    let byteCount: Int
}

protocol ClipboardImageSource: Sendable {
    func readImage() throws -> EncodedImage
}

protocol CredentialProvider: Sendable {
    func credentials() async throws -> R2Credentials
}

protocol ObjectKeyGenerating: Sendable {
    func makeKey(prefix: String, date: Date, fileExtension: String) throws -> String
}

protocol RequestSigning: Sendable {
    func signedPUT(
        url: URL,
        contentType: String,
        payload: Data,
        credentials: R2Credentials,
        date: Date
    ) throws -> URLRequest
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> (HTTPURLResponse, Data)
}

protocol ImageUploading: Sendable {
    func uploadClipboardImage() async throws -> UploadReceipt
}
```

生产实现分别使用 `NSPasteboard`、Security framework、CryptoKit/CommonCrypto、`URLSession`；测试实现使用固定时钟、固定 UUID、内存凭证和捕获请求的 fake transport。预签名模式可复用 `HTTPTransport` 和图片/对象策略，但以 `PresignedUploadAuthorizing` 替换本地 `CredentialProvider` 与 `RequestSigning`。

关键测试矩阵：

- 使用公开 AWS SigV4 固定向量验证 canonical request、scope、signed headers 和最终签名；另测空格、Unicode、`+`、多层路径的逐段编码。
- 固定日期/UUID 时对象键完全确定；非法前缀全部拒绝。
- PNG/JPEG 的字节、扩展名和 `Content-Type` 一致；超限图片不会请求网络。
- fake transport 验证 PUT body 与签名哈希对应，且公开 URL 使用公开基址而非 S3 endpoint。
- 403/429/5xx/取消/超时分别符合重试策略，重试期间对象键和 body 不变。
- 日志捕获测试断言 access key、secret、Authorization、预签名查询串和图片字节均未出现。
- Keychain provider 的 not-found、locked、denied 状态映射为稳定错误；发布构建不存在 env provider 注册路径。

## 6. 凭证迁移方案

1. 创建专用 R2 token/bucket，并先确认其实际权限范围；不要直接复用权限更大的运维凭证作为长期方案。
2. 提供一次性、显式触发的迁移命令或设置页。迁移器只从当前进程环境读取 `R2_ACCESS_KEY_ID` 和 `R2_SECRET_ACCESS_KEY`，写入 Keychain 后立即做一次不泄密的读取一致性检查。
3. 非秘密字段迁入应用配置；保留变量名映射，不复制原 `.env` 文件。迁移结果只报告字段名和成功/失败状态。
4. 使用测试对象完成上传、公开 URL 访问和删除清理的人工验收。清理由受控运维工具完成，客户端不因此获得删除权限。
5. 确认新路径稳定后，撤销旧 token，并由凭证所有者从原 env 删除旧字段；删除属于单独的显式变更，不由客户端自动执行。
6. 对可分发版本迁移到预签名服务：服务端轮换 R2 token，客户端删除 Keychain item，并移除 direct-SigV4 能力。保留应急撤销、轮换和审计流程。

若导入或验证任一步失败，保留原配置，不撤销旧 token，不落盘任何临时明文，并允许安全重试。迁移工具不得通过 shell 参数接收秘密，因为参数可能进入 shell history 或进程列表。

## 7. 安全验收标准

- [ ] 唯一写入产物是本设计文档；原 `.env` 和应用源码未改动。
- [ ] 应用包、Git、`UserDefaults`、日志、崩溃报告、命令行参数和网络日志中不存在 R2 secret 或 `Authorization`。
- [ ] 发布构建不读取固定 `.env` 路径，也不注册 env credential provider。
- [ ] 本机直接模式的秘密仅位于 `ThisDeviceOnly` Keychain item；锁定、拒绝和缺失状态均安全失败。
- [ ] 可分发模式不持有长期 R2 凭证；预签名 URL 限定方法、对象键、类型、大小且不超过 5 分钟。
- [ ] endpoint 与公开基址均强制 HTTPS；对象键无法越出新前缀，且不含个人信息或内容衍生标识。
- [ ] SigV4 固定向量、特殊字符路径、内容哈希和时钟偏差测试通过。
- [ ] 上传的实际字节、`Content-Type`、扩展名和签名哈希完全一致。
- [ ] 只有 2xx 返回成功；权限错误不重试，429/5xx/瞬断按上限退避，取消立即生效。
- [ ] 公开 URL 由配置的公开基址和相同对象键构造，测试证明不会泄漏 S3 endpoint 或签名参数。
- [ ] 用户在上传前知道图片将公开；剪贴板为空、格式不支持、超限和网络失败均给出不泄密的可操作提示。
- [ ] token 已在专用 bucket 上按平台能力缩到最小权限；无法实施前缀/动作级限制时已有预签名服务或专用 bucket 补偿。
- [ ] 旧凭证完成验证后已撤销，迁移中间态可回滚且没有额外明文副本。

## 8. 未决项与实施前验证

实施前仍需在不输出秘密的前提下确认：现有 endpoint 是账户级还是已含 bucket 的形态、公开基址是否为生产 custom domain、bucket 的公开策略、单对象大小上限、允许的图片格式、目标新前缀，以及 R2 token 在当前账户可实现的最细权限。上述任一项不明确时应让配置校验显式失败，不能靠字符串猜测或自动降级。
