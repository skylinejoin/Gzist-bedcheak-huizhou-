# 免责声明 / Disclaimer

> 本文件是 [README.md](README.md) 的组成部分。**使用本项目即表示你已阅读、理解并接受本声明全部内容。**

## 一、用途限定

本项目（下称"本工具"）是**个人技术学习实践**，用于把「**本人账号**在**本人确实身处宿舍**时所需完成的一次查寝签到」自动化。

**本工具不代替你到场，也不改变"你必须人在宿舍"这一事实前提。**

## 二、明确禁止的用途

以下行为被作者明确反对，且可能违反校纪校规、学校信息系统管理规定甚至法律法规：

1. **替他人签到 / 代签 / 批量签到**（无论是否收费）；
2. **人不在宿舍、不在学校时**使用定位注入伪造"在场"记录；
3. 绕过、对抗、破坏学校的考勤制度或信息系统安全机制（如破解风控、伪造设备指纹、攻击服务器）；
4. 将本工具用于任何形式的**营利、代练、代签服务**；
5. 在未获得账号所有人知情同意的情况下操作他人账号。

## 三、关于"定位注入"的特别说明

本工具的定位注入**不是伪造位置的手段，而是修复定位故障的补丁**：

- 学校页面依赖浏览器 `navigator.geolocation` 判定是否在考勤范围；
- 实测中 Windows 定位服务经常**超时失败**，或返回**基于 IP 的粗定位**（偏差可达上百公里）；
- 结果是**人在宿舍也被判"不在考勤范围"**，无法完成签到；
- 因此本工具允许在页面加载前注入**你本人真实所在位置**的坐标，使页面恢复正确判断。

**前提条件（不可协商）**：注入的坐标必须**等于你本人此刻真实所在的位置**。
**人不在该位置时，必须**：把 `_定位注入.启用` 设为 `false`，或直接停用每日任务（`13-假期模式(离校停用).bat`）。

## 四、风险与责任

使用本工具可能带来的风险包括但不限于：

| 风险 | 说明 |
|---|---|
| 纪律处分 | 学校可能将自动化签到认定为违规行为 |
| 账号封禁 | 系统风控可能识别自动化行为并限制账号 |
| 数据风险 | `edge-userdata\` 含登录 Cookie；`signin.log`/`shots\` 含页面文本与截图，泄露等同泄露个人信息 |
| 功能失效 | 学校页面改版会导致脚本失效（不保证长期可用） |

**上述风险及一切后果由使用者自行承担。作者不提供任何明示或暗示的担保，不对任何直接或间接损失负责。**

## 五、数据处理

- 本工具**不向任何服务器上报数据**，无遥测、无统计、无第三方依赖；
- **不读取、不存储账号密码**：登录依赖浏览器自身已保存的凭据自动填充；
- 所有日志、截图、浏览器配置目录均**只存在于本机**；
- 使用者有责任**不将上述数据公开**（见《发布前检查清单》与 `.gitignore`）。

## 六、非官方声明

本工具为个人作品，**与任何学校、院系、教师、厂商均无关联**，未获其授权或认可，不代表其立场。

## 七、停止使用

如学校、系统管理员、账号所有人或作者本人要求，**应立即停止使用并删除本工具及其产生的全部本地数据**。

## 八、许可与免责的关系

本项目以 MIT License 发布，该许可**仅涉及代码版权**，**不免除**使用者遵守所在学校规章制度与所在地法律法规的义务。本免责声明是本项目的使用前提；若你不同意其中任何一条，请勿使用本项目。

---

*English summary: This tool automates a single check-in click for **your own account** while **you are physically present in your dormitory**. It must not be used for signing in on behalf of others, or for faking presence when you are elsewhere. Geolocation override exists solely to repair broken/failed browser geolocation, and must always reflect your real position. You are solely responsible for any consequence, including disciplinary action or account suspension. Not affiliated with any institution. Provided "as is", without warranty of any kind.*
