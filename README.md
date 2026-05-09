# 🤖 Salesforce AI Agent

> An intelligent AI-powered assistant built **natively inside Salesforce** using Lightning Web Components (LWC) and Apex — no AppExchange, no plugins.

Ask questions in plain English and get instant answers from your live org — picklist fields, object metadata, permission sets, OWD settings, SOQL results, Apex code, LWC components, and more.

---

## 📸 Demo

![Salesforce AI Agent UI](./assets/demo-screenshot.png)

> *The agent answering a live org query — picklist fields on the Account object, fetched in real time via Schema.describe()*

---

## ✨ Features

| Capability | Description |
|---|---|
| 🗂 **Object Metadata** | Describe any object — all fields, data types, child relationships |
| 📋 **Live SOQL** | Executes real queries against your org and displays results in a table |
| 🎨 **Picklist Fields** | Lists all picklist fields on any object with API names and types |
| 🎯 **Picklist Values** | Shows all LOVs (List of Values) for a specific field with active/default status |
| 🔒 **OWD & Sharing** | Object sharing info via Schema describe |
| 🛡 **Permission Sets** | Lists all custom permission sets in the org |
| 🗂 **PS Groups** | Lists all permission set groups |
| 👥 **Profiles & Roles** | Lists all profiles and user roles |
| 📦 **Custom Objects** | Lists all custom objects in the org |
| ⚡ **Flows** | Lists all flows with their type and active status |
| ⚙️ **Apex Classes** | Lists all Apex classes with status and last modified date |
| 💻 **Apex Code** | Generates production-ready Apex triggers, classes, batch jobs |
| 🖥 **LWC Components** | Generates complete LWC with HTML, JS, CSS, and meta XML |
| 🔍 **SOQL Generation** | Writes SOQL queries with proper filters, ORDER BY, and LIMIT |
| 👤 **User Info** | Shows current user details, org ID, profile, and role |

---

## 🧠 How It Works

The agent uses **intent detection** to route each question to the right handler:

```
User Prompt
     │
     ▼
┌─────────────────────────────┐
│   isCodeOrExplanationRequest│  ──► GPT-4 (code/explanation)
└─────────────────────────────┘
     │ (not code)
     ▼
┌─────────────────────────────┐
│   tryNativeOrgHandler       │  ──► Live Salesforce org (Schema/SOQL)
└─────────────────────────────┘
     │ (not matched)
     ▼
┌─────────────────────────────┐
│   generateSoqlQuery (GPT)   │  ──► Execute SOQL → format results
└─────────────────────────────┘
     │ (NO_QUERY)
     ▼
┌─────────────────────────────┐
│   callOpenAIChat            │  ──► GPT-4 general answer
└─────────────────────────────┘
```

- **Ask for data** → queries your live org directly via Schema.describe() or Database.query()
- **Ask for code** → routes to GPT-4 for Apex, LWC, or SOQL generation
- **Ask for an explanation** → routes to GPT-4 for concepts and best practices

---

## 📁 Project Structure

```
salesforce-ai-agent/
├── force-app/
│   └── main/
│       └── default/
│           ├── classes/
│           │   ├── SfAiAgentController.cls
│           │   └── SfAiAgentController.cls-meta.xml
│           └── lwc/
│               └── sfAiAgent/
│                   ├── sfAiAgent.html
│                   ├── sfAiAgent.js
│                   ├── sfAiAgent.css
│                   └── sfAiAgent.js-meta.xml
├── assets/
│   └── demo-screenshot.png
├── sfdx-project.json
└── README.md
```

---

## 🚀 Setup & Deployment

### Prerequisites

- Salesforce org (Developer Edition, Sandbox, or Production)
- [Salesforce CLI](https://developer.salesforce.com/tools/sfdxcli) installed
- [OpenAI API key](https://platform.openai.com/api-keys) (GPT-4 access)
- VS Code with [Salesforce Extension Pack](https://marketplace.visualstudio.com/items?itemName=salesforce.salesforcedx-vscode)

---

### Step 1 — Clone the Repository

```bash
git clone https://github.com/abuawaish/salesforce-ai-agent.git
cd salesforce-ai-agent
```

---

### Step 2 — Authenticate to Your Org

```bash
# Login to your org
sf org login web --alias my-org

# Or for a sandbox
sf org login web --alias my-sandbox --instance-url https://test.salesforce.com
```

---

### Step 3 — Create the Named Credential (CRITICAL)

This is how your Apex controller calls the OpenAI API securely — **your API key never appears in code**.

#### 3a. Create a Remote Site Setting

1. Go to **Setup** → search **Remote Site Settings** → click **New**
2. Fill in:

| Field | Value |
|---|---|
| Remote Site Name | `OpenAI_API` |
| Remote Site URL | `https://api.openai.com` |
| Active | ✅ Checked |

3. Click **Save**

---

#### 3b. Create the Named Credential

1. Go to **Setup** → search **Named Credentials** → click **New Legacy**
2. Fill in:

| Field | Value |
|---|---|
| Label | `OpenAI API` |
| Name | `OpenAI_API` |
| URL | `https://api.openai.com` |
| Identity Type | `Named Principal` |
| Authentication Protocol | `No Authentication` |
| Generate Authorization Header | ❌ Unchecked |

3. Click **Save**

---

#### 3c. Add Your API Key as a Custom Header

1. After saving, click **Edit** on the Named Credential you just created
2. Scroll down to **Custom Headers** section → click **New**
3. Add:

| Header Name | Value |
|---|---|
| `Authorization` | `Bearer sk-YOUR-OPENAI-KEY-HERE` |

> ⚠️ Replace `sk-YOUR-OPENAI-KEY-HERE` with your actual OpenAI API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys)

4. Click **Save**

> ✅ Your API key is now stored securely in Salesforce vault. It will never appear in Apex code or LWC — Salesforce automatically injects it into every callout.

---

### Step 4 — Deploy to Your Org

```bash
# Deploy all metadata
sf project deploy start --source-dir force-app --target-org my-org

# Verify deployment
sf project deploy report
```

---

### Step 5 — Grant Permissions

1. Go to **Setup** → **Permission Sets** → **New**
2. Create a permission set named `SF AI Agent User`
3. Under **Apex Class Access** → click **Edit** → add `SfAiAgentController` → **Save**
4. Assign the permission set to yourself and any other users

---

### Step 6 — Add to Your App

1. Go to **Setup** → **App Manager** → find your app → click **Edit**
2. Under **Navigation Items** → click **Add More Items**
3. Select **Lightning Component Tabs** → search for `sfAiAgent` → add it
4. Click **Save & Finish**
5. Refresh your Salesforce app — the **SF AI Agent** tab will appear

---

## 💬 Example Prompts

### Org Data Queries
```
Show me all picklist fields on the Account object
Describe the Opportunity object with all fields and child relationships
List all permission sets in this org
Show OWD settings for this org
Who am I? Show my user info
List all active flows
Show all Apex classes
Show validation rules for Account
List all custom objects
Show picklist values for Account.Industry
```

### Code Generation
```
Write an Apex trigger on Opportunity that fires on insert and update
Create an LWC component that shows related Contacts using @wire
Write SOQL to get all Accounts in Technology industry with AnnualRevenue > 1M
How do I handle governor limits in Apex batch jobs?
Explain the difference between lookup and master-detail relationships
Write a batch Apex class to update all Account records
```

---

## 🔧 Configuration

### Switching AI Models

In `SfAiAgentController.cls`, find the `callOpenAI` method and change the model:

```apex
body.put('model', 'gpt-4o-mini');   // fast, cost-effective (default)
body.put('model', 'gpt-4o');         // more capable, higher cost
body.put('model', 'gpt-4-turbo');    // alternative option
```

### Adjusting Response Length

```apex
body.put('max_tokens', 1500);   // increase for longer code responses
```

### Adjusting AI Creativity

```apex
body.put('temperature', 0.2);   // 0.0 = precise/deterministic, 1.0 = creative
```

---

## 🏗 Built With

| Technology | Purpose |
|---|---|
| **Lightning Web Components (LWC)** | Frontend chat UI |
| **Apex** | Backend controller, org queries, API callout |
| **Schema.describe()** | Live object/field metadata without SOQL |
| **Database.query()** | Dynamic SOQL execution |
| **OpenAI GPT-4** | Code generation and explanations |
| **Salesforce Named Credentials** | Secure API key storage |

---

## 🔒 Security Notes

- The OpenAI API key is stored in a **Named Credential** — it is never hardcoded in Apex or exposed in LWC
- The Apex class uses `with sharing` — it respects the running user's record-level access
- All SOQL queries run in the context of the logged-in user's permissions
- Dynamic SOQL is validated to only allow `SELECT` statements — no DML operations possible

---

## 🤝 Contributing

Contributions are welcome! Here are some ideas for improvements:

- [ ] Add support for Claude (Anthropic) as an alternative LLM
- [ ] Add conversation history persistence using Custom Objects
- [ ] Add support for Tooling API queries (OWD, Validation Rules)
- [ ] Add voice input support
- [ ] Add export conversation to PDF feature
- [ ] Support for multiple orgs / org switching

To contribute:

```bash
# Fork the repo, then:
git checkout -b feature/your-feature-name
git commit -m "Add: your feature description"
git push origin feature/your-feature-name
# Open a Pull Request
```

---

## 📄 License

MIT License — free to use, modify, and distribute. See [LICENSE](./LICENSE) for details.

---

## 👨‍💻 Author

**Abu Awaish**

- LinkedIn: [linkedin.com/in/abuawaish](https://www.linkedin.com/in/abu-awaish-a6523b258/)
- GitHub: [github.com/AbuAwaish](https://github.com/abuawaish)

---

## ⭐ If this helped you

Give it a ⭐ on GitHub — it helps others discover the project!

Drop a comment on my [LinkedIn post](#) if you want to share how you're using it.