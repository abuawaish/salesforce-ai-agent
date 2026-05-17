/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : SfAiAgentController
 * Author          : Abu Awaish
 * Created Date    : May 7, 2026
 * Last Modified By: Abu Awaish
 * Last Modified On: May 16, 2026
 * Description     : SF AI Agent — intent-aware routing, native org queries,
 *                   dynamic SOQL execution, OpenAI GPT-4 fallback
 *
 * Change History  :
 *  Date          │ Author      │ Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 07, 2026  │ Abu Awaish  │ Initial version
 *  May 08, 2026  │ Abu Awaish  │ Fixed Named Credential auth bug
 *  May 09, 2026  │ Abu Awaish  │ Added intent detection + native org handlers
 *  May 10, 2026  │ Abu Awaish  │ Fixed OWD + ValidationRule compile errors
 *  May 11, 2026  │ Abu Awaish  │ Added subquery support + field access fix
 *  May 12, 2026  │ Abu Awaish  │ Split describeObject into focused methods
 *  May 13, 2026  │ Abu Awaish  │ Added PS/PSG/ApexClass/Flow/Profile detail
 *  May 16, 2026  │ Abu Awaish  │ Fixed record fetch routing, dynamic SOQL
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

public with sharing class SfAiAgentController {

    // ══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ══════════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static String askAgent(String prompt) {
        try {
            if (String.isBlank(prompt)) {
                throw new AuraHandledException('Prompt cannot be empty.');
            }

            // 1. Code/explanation requests → straight to GPT
            if (isCodeOrExplanationRequest(prompt)) {
                return callOpenAIChat(prompt);
            }

            // 2. Native org handlers (metadata, permissions, users, etc.)
            String nativeResult = tryNativeOrgHandler(prompt);
            if (nativeResult != null) return nativeResult;

            // 3. Ask GPT to generate SOQL, then execute it
            String soql = generateSoqlQuery(prompt);
            if (isValidSelectQuery(soql)) {
                return executeSoqlAndFormat(soql);
            }

            // 4. General GPT answer
            return callOpenAIChat(prompt);

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            System.debug('Exception: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AuraHandledException('Unexpected error: ' + e.getMessage());
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INTENT DETECTION
    // ══════════════════════════════════════════════════════════════════════════

    private static Boolean isCodeOrExplanationRequest(String prompt) {
        String lp = prompt.toLowerCase();

        if (lp.contains('write apex')         || lp.contains('create apex')      ||
            lp.contains('write a trigger')    || lp.contains('write trigger')    ||
            lp.contains('create trigger')     || lp.contains('write lwc')        ||
            lp.contains('create lwc')         || lp.contains('lwc component')    ||
            lp.contains('how to ')            || lp.contains('how do i')         ||
            lp.contains('how does')           || lp.contains('explain ')         ||
            lp.contains('what is ')           || lp.contains('what are ')        ||
            lp.contains('difference between') || lp.contains('best practice')    ||
            lp.contains('example of')         || lp.contains('syntax for')       ||
            // SOQL generation keywords — all variations
            lp.contains('write soql')         || lp.contains('give me soql')     ||
            lp.contains('only soql')          || lp.contains('generate soql')    ||
            lp.contains('soql for ')          || lp.contains('soql to ')         ||
            lp.contains('soql query')         || lp.contains('soql query only')  ||
            lp.contains('show me soql')       || lp.contains('show me a soql')   ||
            lp.contains('generate a soql')    || lp.contains('create a soql')    ||
            lp.contains('get soql')           || lp.contains('need soql')) {
            return true;
        }
        return false;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // NATIVE ORG HANDLER — priority-ordered routing
    // ══════════════════════════════════════════════════════════════════════════

    private static String tryNativeOrgHandler(String prompt) {
        String lp = prompt.toLowerCase();

        // ── PRIORITY 1 — Record/data fetch → let SOQL generator handle ────────
        Boolean isRecordFetch =
            lp.contains('top ')          || lp.contains('fetch ')       ||
            lp.contains('get me ')       || lp.contains('get top')      ||
            lp.contains('retrieve ')     || lp.contains('find me')      ||
            lp.contains('having id')     || lp.contains('where id')     ||
            lp.contains('limit ')        || lp.contains('only one')     ||
            lp.contains('one record')    || lp.contains('records of')   ||
            lp.contains('records from')  || lp.contains('records with') ||
            (lp.contains('show me ') && lp.contains('record'));

        if (isRecordFetch) return null;

        // ── PRIORITY 2 — User info ─────────────────────────────────────────────
        if (lp.contains('my username')  || lp.contains('who am i')      ||
            lp.contains('my email')     || lp.contains('my name')       ||
            lp.contains('current user') || lp.contains('my user info')  ||
            lp.contains('my org')) {
            return getCurrentUserInfo();
        }

        // ── PRIORITY 3 — Picklist VALUES (specific field with dot notation) ────
        Boolean hasFieldNotation = lp.contains('.');
        Boolean asksForValues    = lp.contains('value') || lp.contains('lov') ||
                                   lp.contains('option');
        if (hasFieldNotation && asksForValues && containsObjectName(lp)) {
            return getPicklistValues(prompt);
        }

        // ── PRIORITY 4 — Picklist FIELDS list ─────────────────────────────────
        Boolean asksPicklistFields =
            lp.contains('picklist field')      || lp.contains('picklist on')   ||
            lp.contains('picklist in')         || lp.contains('picklists on')  ||
            lp.contains('picklists in')        || lp.contains('all picklist')  ||
            lp.contains('available picklist')  || lp.contains('show picklist') ||
            lp.contains('list picklist');

        if (asksPicklistFields && containsObjectName(lp)) {
            return getPicklistFields(prompt);
        }

        // ── PRIORITY 5 — Children only ─────────────────────────────────────────
        Boolean asksChildrenOnly =
            lp.contains('child object')       || lp.contains('child relationship') ||
            lp.contains('children of')        || lp.contains('related object');

        if (asksChildrenOnly && containsObjectName(lp)) {
            return getObjectChildren(extractObjectName(prompt));
        }

        // ── PRIORITY 6 — Full describe (fields + children) ────────────────────
        Boolean asksFullDescribe =
            lp.contains('describe ')    || lp.contains('full schema') ||
            lp.contains('object info')  || lp.contains('schema of')  ||
            lp.contains('full info');

        Boolean isPicklistRelated = lp.contains('picklist');

        if (!isPicklistRelated && asksFullDescribe && containsObjectName(lp)) {
            return describeObject(extractObjectName(prompt));
        }

        // ── PRIORITY 7 — Fields only (pure metadata, not record fetch) ─────────
        Boolean asksFieldsOnly =
            (lp.contains('all fields')         ||
             lp.contains('list fields')         ||
             lp.contains('show fields')         ||
             lp.contains('field list')          ||
             lp.contains('fields and their')    ||
             lp.contains('fields with their')   ||
             lp.contains('fields of the')       ||
             lp.contains('fields on the')       ||
             lp.contains('data types'))
            && !lp.contains('record')
            && !lp.contains('fetch')
            && !lp.contains('get me')
            && !lp.contains('retrieve')
            && !lp.contains('picklist')
            && !lp.contains('child')
            && !lp.contains('relationship');

        if (asksFieldsOnly && containsObjectName(lp)) {
            return getObjectFields(extractObjectName(prompt));
        }

        // ── PRIORITY 8 — OWD ──────────────────────────────────────────────────
        if (lp.contains('owd')              || lp.contains('org-wide')        ||
            lp.contains('org wide')         || lp.contains('sharing default') ||
            lp.contains('default sharing')  || lp.contains('sharing setting')) {
            return getOwdSettings();
        }

        // ── PRIORITY 9 — Permission Set detail OR list ────────────────────────
        if (lp.contains('permission set') && !lp.contains('group')) {
            Boolean wantsSpecific =
                lp.contains('detail')    || lp.contains('named ')   ||
                lp.contains('called ')   || lp.contains('equals')   ||
                lp.contains(' = ')       || lp.contains('about ')   ||
                lp.contains('specific')  || lp.contains('full')     ||
                lp.contains('"')         || lp.contains('\'');

            if (wantsSpecific) return getPermissionSetDetail(prompt);

            if (lp.contains('list') || lp.contains('all') ||
                lp.contains('show') || lp.contains('fetch')) {
                return getPermissionSets();
            }
        }

        // ── PRIORITY 10 — Permission Set Group detail OR list ─────────────────
        if (lp.contains('permission set group') || lp.contains('psg')) {
            Boolean wantsSpecific =
                lp.contains('detail')   || lp.contains('named ')  ||
                lp.contains('called ')  || lp.contains('equals')  ||
                lp.contains(' = ')      || lp.contains('about ')  ||
                lp.contains('full')     || lp.contains('"')       ||
                lp.contains('\'');

            if (wantsSpecific) return getPermissionSetGroupDetail(prompt);

            if (lp.contains('list') || lp.contains('all') || lp.contains('show')) {
                return getPermissionSetGroups();
            }
        }

        // ── PRIORITY 11 — Profiles ─────────────────────────────────────────────
        if (lp.contains('profile')) {
            Boolean wantsSpecific =
                lp.contains('detail')    || lp.contains('named ')  ||
                lp.contains('called ')   || lp.contains('equals')  ||
                lp.contains('whose name')|| lp.contains(' = ')     ||
                lp.contains('full')      || lp.contains('"')       ||
                lp.contains('\'');

            if (wantsSpecific) return getProfileDetail(prompt);

            if (lp.contains('list') || lp.contains('all') || lp.contains('show')) {
                return getProfiles();
            }
        }

        // ── PRIORITY 12 — Roles ───────────────────────────────────────────────
        if ((lp.contains('user role')  || lp.contains('user roles') ||
             lp.contains('all roles')  || lp.contains('list roles') ||
             lp.contains('show roles')) && !lp.contains('my')) {
            return getUserRoles();
        }

        // ── PRIORITY 13 — Custom objects ──────────────────────────────────────
        if ((lp.contains('custom object') || lp.contains('all object')) &&
            (lp.contains('list') || lp.contains('show') || lp.contains('all'))) {
            return listCustomObjects();
        }

        // ── PRIORITY 14 — Installed packages ──────────────────────────────────
        if (lp.contains('installed package') || lp.contains('managed package')) {
            return getInstalledPackages();
        }

        // ── PRIORITY 15 — Flow detail OR list ────────────────────────────────────
        if (lp.contains('flow') && !lp.contains('soql') && !lp.contains('query')) {
            Boolean wantsSpecific =
                lp.contains('detail')     || lp.contains('named ')    ||
                lp.contains('called ')    || lp.contains('equals')    ||
                lp.contains(' = ')        || lp.contains('about ')    ||
                lp.contains('full')       || lp.contains('whose name')||
                lp.contains('"')          || lp.contains('\'');
            if (wantsSpecific) return getFlowDetail(prompt);

            if (lp.contains('list') || lp.contains('all') || lp.contains('active')) {
                return getFlows();
            }
        }

        // ── PRIORITY 16 — Apex classes ────────────────────────────────────────
        if (lp.contains('apex class') || lp.contains('apex classes')) {

            Boolean wantsSpecific =
                lp.contains('detail')    || lp.contains('info')     ||
                lp.contains('named ')    || lp.contains('called ')  ||
                lp.contains('whose name')|| lp.contains('equals')   ||
                lp.contains(' = ')       || lp.contains('about ')   ||
                lp.contains('specific')  || lp.contains('full')     ||
                lp.contains('"')         || lp.contains('\'');

            if (wantsSpecific) return getApexClassDetail(prompt);

            if (lp.contains('list') || lp.contains('all') || lp.contains('show')) {
                return getApexClasses();
            }
        }

        // ── PRIORITY 17 — Validation rules ───────────────────────────────────
        if (lp.contains('validation rule') &&
            (lp.contains('list') || lp.contains('show') || lp.contains('all') ||
             containsObjectName(lp))) {
            return getValidationRules(prompt);
        }

        // ── PRIORITY 18 — Record types ────────────────────────────────────────
        if (lp.contains('record type') &&
            (lp.contains('list') || lp.contains('show') || lp.contains('all') ||
             containsObjectName(lp))) {
            return getRecordTypes(prompt);
        }

        // ── PRIORITY 19 — Active users ────────────────────────────────────────
        if ((lp.contains('all user')   || lp.contains('list user') ||
             lp.contains('show user')  || lp.contains('active user')) &&
             !lp.contains('my')) {
            return getActiveUsers();
        }

        return null;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ORG DATA METHODS
    // ══════════════════════════════════════════════════════════════════════════

    // ── Current user info ─────────────────────────────────────────────────────
    private static String getCurrentUserInfo() {
        User u = [
            SELECT Id, Name, Username, Email, Profile.Name,
                   UserRole.Name, IsActive, LastLoginDate
            FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
        ];
        return '## 👤 Your Salesforce User\n\n'
             + '| Field | Value |\n|---|---|\n'
             + '| **Name** | '       + u.Name + ' |\n'
             + '| **Username** | `'  + u.Username + '` |\n'
             + '| **Email** | '      + u.Email + ' |\n'
             + '| **Profile** | '    + (u.Profile   != null ? u.Profile.Name   : '—') + ' |\n'
             + '| **Role** | '       + (u.UserRole  != null ? u.UserRole.Name  : '—') + ' |\n'
             + '| **Last Login** | ' + (u.LastLoginDate != null ? String.valueOf(u.LastLoginDate).substring(0,10) : 'Never') + ' |\n'
             + '| **Org ID** | `'    + UserInfo.getOrganizationId()   + '` |\n'
             + '| **Org Name** | '   + UserInfo.getOrganizationName() + ' |';
    }

    // ── Fields only ───────────────────────────────────────────────────────────
    private static String getObjectFields(String objectName) {
        if (String.isBlank(objectName))
            return '❌ Please specify an object. Example: "Show fields on Contact"';
        try {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
            if (sot == null) return '❌ Object `' + objectName + '` not found.';

            Schema.DescribeSObjectResult dsr = sot.getDescribe();
            Map<String, Schema.SObjectField> fields = dsr.fields.getMap();
            List<String> fieldNames = new List<String>(fields.keySet());
            fieldNames.sort();

            String result = '## 🗂 `' + dsr.getLabel() + '` — Fields (' + fields.size() + ')\n\n'
                          + '| # | Label | API Name | Type | Required |\n|---|---|---|---|---|\n';

            Integer idx = 1;
            for (String fn : fieldNames) {
                Schema.DescribeFieldResult f = fields.get(fn).getDescribe();
                result += '| ' + idx++
                        + ' | ' + f.getLabel()
                        + ' | `' + f.getName() + '`'
                        + ' | ' + f.getType()
                        + ' | ' + (f.isNillable() ? '' : '✅') + ' |\n';
            }
            return result;
        } catch (Exception e) {
            return '❌ Error: ' + e.getMessage();
        }
    }

    // ── Child relationships only ───────────────────────────────────────────────
    private static String getObjectChildren(String objectName) {
        if (String.isBlank(objectName))
            return '❌ Please specify an object. Example: "Show child objects of Account"';
        try {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
            if (sot == null) return '❌ Object `' + objectName + '` not found.';

            Schema.DescribeSObjectResult dsr = sot.getDescribe();
            List<Schema.ChildRelationship> children = dsr.getChildRelationships();

            String result = '## 🔗 `' + dsr.getLabel() + '` — Child Relationships (' + children.size() + ')\n\n'
                          + '| # | Child Object | Relationship Name | Field |\n|---|---|---|---|\n';

            Integer idx = 1;
            for (Schema.ChildRelationship cr : children) {
                if (cr.getRelationshipName() == null) continue;
                result += '| ' + idx++
                        + ' | `' + cr.getChildSObject().getDescribe().getName() + '`'
                        + ' | ' + cr.getRelationshipName()
                        + ' | `' + cr.getField().getDescribe().getName() + '` |\n';
            }
            return result;
        } catch (Exception e) {
            return '❌ Error: ' + e.getMessage();
        }
    }

    // ── Full describe (fields + children) ─────────────────────────────────────
    private static String describeObject(String objectName) {
        if (String.isBlank(objectName))
            return '❌ Could not detect object name. Try: "describe Account"';
        try {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
            if (sot == null) return '❌ Object `' + objectName + '` not found.';

            Schema.DescribeSObjectResult dsr = sot.getDescribe();
            Map<String, Schema.SObjectField> fields   = dsr.fields.getMap();
            List<Schema.ChildRelationship>   children = dsr.getChildRelationships();

            String result = '## 🗂 `' + dsr.getLabel() + '` (`' + dsr.getName() + '`)\n\n'
                          + '**Total Fields:** ' + fields.size()
                          + '  ·  **Child Relationships:** ' + children.size() + '\n\n'
                          + '### Fields\n\n'
                          + '| # | Label | API Name | Type | Required |\n|---|---|---|---|---|\n';

            List<String> fieldNames = new List<String>(fields.keySet());
            fieldNames.sort();
            Integer idx = 1;
            for (String fn : fieldNames) {
                Schema.DescribeFieldResult f = fields.get(fn).getDescribe();
                result += '| ' + idx++
                        + ' | ' + f.getLabel()
                        + ' | `' + f.getName() + '`'
                        + ' | ' + f.getType()
                        + ' | ' + (f.isNillable() ? '' : '✅') + ' |\n';
            }

            result += '\n### Child Relationships\n\n'
                    + '| # | Child Object | Relationship Name | Field |\n|---|---|---|---|\n';
            Integer ci = 1;
            for (Schema.ChildRelationship cr : children) {
                if (cr.getRelationshipName() == null) continue;
                result += '| ' + ci++
                        + ' | `' + cr.getChildSObject().getDescribe().getName() + '`'
                        + ' | ' + cr.getRelationshipName()
                        + ' | `' + cr.getField().getDescribe().getName() + '` |\n';
            }
            return result;
        } catch (Exception e) {
            return '❌ Error describing object: ' + e.getMessage();
        }
    }

    // ── OWD / sharing info ────────────────────────────────────────────────────
    private static String getOwdSettings() {
        try {
            List<String> objectsToCheck = new List<String>{
                'Account','Contact','Opportunity','Lead','Case','Campaign',
                'Contract','Order','Asset','Quote','Task','Event','Product2'
            };

            String result = '## 🔒 Object Sharing Info\n\n'
                          + '| Object | Queryable | Createable | Has Share Object |\n|---|---|---|---|\n';

            Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
            for (String objName : objectsToCheck) {
                Schema.SObjectType sot = gd.get(objName);
                if (sot == null) continue;
                Schema.DescribeSObjectResult dsr = sot.getDescribe();
                Boolean hasShareObj = gd.containsKey(objName + 'Share');
                result += '| `' + objName + '`'
                        + ' | ' + (dsr.isQueryable()  ? '✅' : '❌')
                        + ' | ' + (dsr.isCreateable() ? '✅' : '❌')
                        + ' | ' + (hasShareObj ? '✅ `' + objName + 'Share`' : '—') + ' |\n';
            }

            result += '\n> ℹ️ Full OWD values (Private/Public Read Only etc.) require Tooling API.\n'
                    + 'To check: **Setup → Sharing Settings**\n\n'
                    + 'Or run in Developer Console with **Use Tooling API** checked:\n'
                    + '```soql\nSELECT SobjectType, InternalSharingModel, ExternalSharingModel\n'
                    + 'FROM OrganizationWideDefault ORDER BY SobjectType\n```';
            return result;
        } catch (Exception e) {
            return '❌ Error: ' + e.getMessage();
        }
    }

    // ── Permission Sets (list) ─────────────────────────────────────────────────
    private static String getPermissionSets() {
        List<PermissionSet> ps = [
            SELECT Id, Label, Name, IsCustom, Description, CreatedDate
            FROM PermissionSet
            WHERE IsOwnedByProfile = false
            ORDER BY Label LIMIT 50
        ];
        if (ps.isEmpty()) return '📋 No custom permission sets found.';
        String result = '## 🛡 Permission Sets (' + ps.size() + ')\n\n'
                      + '| Label | API Name | Custom | Created |\n|---|---|---|---|\n';
        for (PermissionSet p : ps)
            result += '| **' + p.Label + '** | `' + p.Name + '` | '
                    + (p.IsCustom ? '✅' : '—') + ' | '
                    + String.valueOf(p.CreatedDate).substring(0,10) + ' |\n';
        return result;
    }

    // ── Permission Set (single detail) ────────────────────────────────────────
    private static String getPermissionSetDetail(String prompt) {
        try {
            String searchName = extractQuotedOrKeywordValue(prompt);
            if (String.isBlank(searchName))
                return '❌ Please specify a name. Example:\n"Show details of permission set SF AI Agent User"';

            List<PermissionSet> results = [
                SELECT Id, Label, Name, IsCustom, Description,
                       CreatedDate, LastModifiedDate,
                       CreatedBy.Name, LastModifiedBy.Name,
                       PermissionsApiEnabled, PermissionsAuthorApex,
                       PermissionsCustomizeApplication, PermissionsManageUsers,
                       PermissionsModifyAllData, PermissionsViewAllData,
                       License.Name
                FROM PermissionSet
                WHERE IsOwnedByProfile = false
                  AND (Label LIKE :('%' + searchName + '%')
                   OR  Name  LIKE :('%' + searchName + '%'))
                ORDER BY Label LIMIT 5
            ];

            if (results.isEmpty())
                return '❌ No permission set found matching **"' + searchName + '"**.\n\n'
                     + 'Try: "List all permission sets" to see what\'s available.';

            if (results.size() > 1) {
                String table = '## 🛡 Multiple Matches for "' + searchName + '"\n\n'
                             + '| Label | API Name | Custom |\n|---|---|---|\n';
                for (PermissionSet p : results)
                    table += '| **' + p.Label + '** | `' + p.Name + '` | '
                           + (p.IsCustom ? '✅' : '—') + ' |\n';
                table += '\n> Be more specific, e.g. "details of permission set ' + results[0].Label + '"';
                return table;
            }

            PermissionSet ps = results[0];
            return '## 🛡 Permission Set Detail\n\n'
                 + '| Field | Value |\n|---|---|\n'
                 + '| **Label** | '           + ps.Label + ' |\n'
                 + '| **API Name** | `'        + ps.Name + '` |\n'
                 + '| **Custom** | '           + (ps.IsCustom ? '✅ Yes' : '— No') + ' |\n'
                 + '| **Description** | '     + (String.isNotBlank(ps.Description) ? ps.Description : '—') + ' |\n'
                 + '| **License** | '         + (ps.License != null ? ps.License.Name : '—') + ' |\n'
                 + '| **Created Date** | '    + String.valueOf(ps.CreatedDate).substring(0,10) + ' |\n'
                 + '| **Created By** | '      + (ps.CreatedBy != null ? ps.CreatedBy.Name : '—') + ' |\n'
                 + '| **Last Modified** | '   + String.valueOf(ps.LastModifiedDate).substring(0,10) + ' |\n'
                 + '| **Last Modified By** | '+ (ps.LastModifiedBy != null ? ps.LastModifiedBy.Name : '—') + ' |\n'
                 + '| **Record ID** | `'       + ps.Id + '` |\n\n'
                 + '### Key Permissions\n\n'
                 + '| Permission | Enabled |\n|---|---|\n'
                 + '| API Enabled | '               + (ps.PermissionsApiEnabled            ? '✅' : '❌') + ' |\n'
                 + '| Author Apex | '               + (ps.PermissionsAuthorApex             ? '✅' : '❌') + ' |\n'
                 + '| Customize Application | '     + (ps.PermissionsCustomizeApplication   ? '✅' : '❌') + ' |\n'
                 + '| Manage Users | '              + (ps.PermissionsManageUsers            ? '✅' : '❌') + ' |\n'
                 + '| Modify All Data | '           + (ps.PermissionsModifyAllData          ? '✅' : '❌') + ' |\n'
                 + '| View All Data | '             + (ps.PermissionsViewAllData            ? '✅' : '❌') + ' |\n';

        } catch (Exception e) {
            return '❌ Error fetching permission set: ' + e.getMessage();
        }
    }

    // ── Permission Set Groups (list) ──────────────────────────────────────────
    private static String getPermissionSetGroups() {
        List<PermissionSetGroup> psg = [
            SELECT Id, MasterLabel, DeveloperName, Status
            FROM PermissionSetGroup
            ORDER BY MasterLabel LIMIT 50
        ];
        if (psg.isEmpty()) return '📋 No permission set groups found.';
        String result = '## 🗂 Permission Set Groups (' + psg.size() + ')\n\n'
                      + '| Label | API Name | Status |\n|---|---|---|\n';
        for (PermissionSetGroup g : psg)
            result += '| **' + g.MasterLabel + '** | `' + g.DeveloperName + '` | ' + g.Status + ' |\n';
        return result;
    }

    // ── Permission Set Group (single detail) ──────────────────────────────────
    private static String getPermissionSetGroupDetail(String prompt) {
        try {
            String searchName = extractQuotedOrKeywordValue(prompt);
            if (String.isBlank(searchName))
                return '❌ Please specify a name. Example:\n"Show details of permission set group Commerce_Shopper"';

            List<PermissionSetGroup> results = [
                SELECT Id, MasterLabel, DeveloperName, Description,
                       Status, CreatedDate, LastModifiedDate,
                       CreatedBy.Name, LastModifiedBy.Name
                FROM PermissionSetGroup
                WHERE MasterLabel   LIKE :('%' + searchName + '%')
                   OR DeveloperName LIKE :('%' + searchName + '%')
                ORDER BY MasterLabel LIMIT 5
            ];

            if (results.isEmpty())
                return '❌ No permission set group found matching **"' + searchName + '"**.\n\n'
                     + 'Try: "List all PS groups" to see available groups.';

            if (results.size() > 1) {
                String table = '## 🗂 Multiple Matches for "' + searchName + '"\n\n'
                             + '| Label | API Name | Status |\n|---|---|---|\n';
                for (PermissionSetGroup g : results)
                    table += '| **' + g.MasterLabel + '** | `' + g.DeveloperName + '` | ' + g.Status + ' |\n';
                table += '\n> Be more specific, e.g. "details of PS group ' + results[0].MasterLabel + '"';
                return table;
            }

            PermissionSetGroup g = results[0];

            List<PermissionSetGroupComponent> members = [
                SELECT PermissionSet.Label, PermissionSet.Name
                FROM PermissionSetGroupComponent
                WHERE PermissionSetGroupId = :g.Id
                LIMIT 20
            ];

            String result = '## 🗂 Permission Set Group Detail\n\n'
                          + '| Field | Value |\n|---|---|\n'
                          + '| **Label** | '            + g.MasterLabel + ' |\n'
                          + '| **API Name** | `'         + g.DeveloperName + '` |\n'
                          + '| **Status** | '           + g.Status + ' |\n'
                          + '| **Description** | '      + (String.isNotBlank(g.Description) ? g.Description : '—') + ' |\n'
                          + '| **Created Date** | '     + String.valueOf(g.CreatedDate).substring(0,10) + ' |\n'
                          + '| **Created By** | '       + (g.CreatedBy != null ? g.CreatedBy.Name : '—') + ' |\n'
                          + '| **Last Modified** | '    + String.valueOf(g.LastModifiedDate).substring(0,10) + ' |\n'
                          + '| **Last Modified By** | ' + (g.LastModifiedBy != null ? g.LastModifiedBy.Name : '—') + ' |\n'
                          + '| **Record ID** | `'        + g.Id + '` |\n';

            if (!members.isEmpty()) {
                result += '\n### Member Permission Sets (' + members.size() + ')\n\n'
                        + '| Label | API Name |\n|---|---|\n';
                for (PermissionSetGroupComponent m : members)
                    result += '| ' + m.PermissionSet.Label + ' | `' + m.PermissionSet.Name + '` |\n';
            }
            return result;

        } catch (Exception e) {
            return '❌ Error fetching PS group: ' + e.getMessage();
        }
    }

    // ── Profiles ──────────────────────────────────────────────────────────────
    private static String getProfiles() {
        List<Profile> profiles = [
            SELECT Id, Name, UserType FROM Profile ORDER BY Name LIMIT 50
        ];
        String result = '## 👥 Profiles (' + profiles.size() + ')\n\n'
                      + '| Name | User Type |\n|---|---|\n';
        for (Profile p : profiles)
            result += '| **' + p.Name + '** | ' + p.UserType + ' |\n';
        return result;
    }

    // ── Profile (single detail) ───────────────────────────────────────────────
    private static String getProfileDetail(String prompt) {
        try {
            String searchName = extractQuotedOrKeywordValue(prompt);
            if (String.isBlank(searchName))
                return '❌ Please specify a profile name. Example:\n"Show details of profile System Administrator"';

            List<Profile> results = [
                SELECT Id, Name, UserType, Description,
                    CreatedDate, LastModifiedDate,
                    CreatedBy.Name, LastModifiedBy.Name,
                    PermissionsApiEnabled, PermissionsAuthorApex,
                    PermissionsModifyAllData, PermissionsViewAllData,
                    PermissionsManageUsers, PermissionsCustomizeApplication
                FROM Profile
                WHERE Name LIKE :('%' + searchName + '%')
                ORDER BY Name LIMIT 5
            ];

            if (results.isEmpty())
                return '❌ No profile found matching **"' + searchName + '"**.\n\n'
                    + 'Try: "List all profiles" to see what\'s available.';

            if (results.size() > 1) {
                String table = '## 👥 Multiple Matches for "' + searchName + '"\n\n'
                            + '| Name | User Type |\n|---|---|\n';
                for (Profile p : results)
                    table += '| **' + p.Name + '** | ' + p.UserType + ' |\n';
                table += '\n> Be more specific, e.g. "details of profile ' + results[0].Name + '"';
                return table;
            }

            Profile p = results[0];
            return '## 👥 Profile Detail\n\n'
                + '| Field | Value |\n|---|---|\n'
                + '| **Name** | '              + p.Name + ' |\n'
                + '| **User Type** | '         + p.UserType + ' |\n'
                + '| **Description** | '       + (String.isNotBlank(p.Description) ? p.Description : '—') + ' |\n'
                + '| **Created Date** | '      + String.valueOf(p.CreatedDate).substring(0,10) + ' |\n'
                + '| **Created By** | '        + (p.CreatedBy != null ? p.CreatedBy.Name : '—') + ' |\n'
                + '| **Last Modified** | '     + String.valueOf(p.LastModifiedDate).substring(0,10) + ' |\n'
                + '| **Last Modified By** | '  + (p.LastModifiedBy != null ? p.LastModifiedBy.Name : '—') + ' |\n'
                + '| **Record ID** | `'         + p.Id + '` |\n\n'
                + '### Key Permissions\n\n'
                + '| Permission | Enabled |\n|---|---|\n'
                + '| API Enabled | '               + (p.PermissionsApiEnabled          ? '✅' : '❌') + ' |\n'
                + '| Author Apex | '               + (p.PermissionsAuthorApex           ? '✅' : '❌') + ' |\n'
                + '| Customize Application | '     + (p.PermissionsCustomizeApplication ? '✅' : '❌') + ' |\n'
                + '| Manage Users | '              + (p.PermissionsManageUsers          ? '✅' : '❌') + ' |\n'
                + '| Modify All Data | '           + (p.PermissionsModifyAllData        ? '✅' : '❌') + ' |\n'
                + '| View All Data | '             + (p.PermissionsViewAllData          ? '✅' : '❌') + ' |\n';

        } catch (Exception e) {
            return '❌ Error fetching profile detail: ' + e.getMessage();
        }
    }

    // ── Roles ─────────────────────────────────────────────────────────────────
    private static String getUserRoles() {
        List<UserRole> roles = [
            SELECT Id, Name, DeveloperName, ParentRoleId
            FROM UserRole ORDER BY Name LIMIT 50
        ];
        String result = '## 🏢 User Roles (' + roles.size() + ')\n\n'
                      + '| Name | API Name | Has Parent |\n|---|---|---|\n';
        for (UserRole r : roles)
            result += '| **' + r.Name + '** | `' + r.DeveloperName + '` | '
                    + (r.ParentRoleId != null ? '✅' : '') + ' |\n';
        return result;
    }

    // ── Picklist VALUES for specific field ────────────────────────────────────
    private static String getPicklistValues(String prompt) {
        String objectName = extractObjectName(prompt);
        String fieldName  = extractFieldName(prompt);

        if (String.isBlank(objectName) || String.isBlank(fieldName))
            return '❌ Please specify both object and field.\n'
                 + 'Example: "Show picklist values for Account.Industry"';
        try {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
            if (sot == null) return '❌ Object `' + objectName + '` not found.';

            Schema.SObjectField fld = sot.getDescribe().fields.getMap().get(fieldName);
            if (fld == null) return '❌ Field `' + fieldName + '` not found on `' + objectName + '`.';

            List<Schema.PicklistEntry> entries = fld.getDescribe().getPicklistValues();
            if (entries.isEmpty())
                return '⚠️ `' + fieldName + '` has no picklist values or is not a picklist field.';

            String result = '## 🎨 Picklist: `' + objectName + '.' + fieldName + '`\n\n'
                          + '**Total:** ' + entries.size() + ' values\n\n'
                          + '| Label | API Value | Active | Default |\n|---|---|---|---|\n';
            for (Schema.PicklistEntry e : entries)
                result += '| ' + e.getLabel() + ' | `' + e.getValue() + '` | '
                        + (e.isActive() ? '✅' : '❌') + ' | '
                        + (e.isDefaultValue() ? '⭐' : '') + ' |\n';
            return result;
        } catch (Exception e) {
            return '❌ Error: ' + e.getMessage();
        }
    }

    // ── Picklist FIELDS on an object ──────────────────────────────────────────
    private static String getPicklistFields(String prompt) {
        String objectName = extractObjectName(prompt);
        if (String.isBlank(objectName))
            return '❌ Please specify an object. Example: "Show picklist fields on Account"';
        try {
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
            if (sot == null) return '❌ Object `' + objectName + '` not found.';

            Map<String, Schema.SObjectField> allFields = sot.getDescribe().fields.getMap();
            List<String> picklistFieldNames = new List<String>();

            for (String fn : allFields.keySet()) {
                Schema.DescribeFieldResult dfr = allFields.get(fn).getDescribe();
                if (dfr.getType() == Schema.DisplayType.PICKLIST ||
                    dfr.getType() == Schema.DisplayType.MULTIPICKLIST) {
                    picklistFieldNames.add(fn);
                }
            }

            if (picklistFieldNames.isEmpty())
                return '📋 No picklist fields found on `' + objectName + '`.';

            picklistFieldNames.sort();
            String result = '## 🎨 Picklist Fields — `' + objectName + '` (' + picklistFieldNames.size() + ')\n\n'
                          + '| Field Label | API Name | Type |\n|---|---|---|\n';
            for (String fn : picklistFieldNames) {
                Schema.DescribeFieldResult dfr = allFields.get(fn).getDescribe();
                result += '| ' + dfr.getLabel() + ' | `' + fn + '` | ' + dfr.getType() + ' |\n';
            }
            return result;
        } catch (Exception e) {
            return '❌ Error: ' + e.getMessage();
        }
    }

    // ── Custom objects ────────────────────────────────────────────────────────
    private static String listCustomObjects() {
        List<EntityDefinition> objs = [
            SELECT QualifiedApiName, Label
            FROM EntityDefinition
            WHERE QualifiedApiName LIKE '%__c'
              AND IsDeprecatedAndHidden = false
            ORDER BY QualifiedApiName LIMIT 100
        ];
        if (objs.isEmpty()) return '📋 No custom objects found.';
        String result = '## 📦 Custom Objects (' + objs.size() + ')\n\n'
                      + '| Label | API Name |\n|---|---|\n';
        for (EntityDefinition o : objs)
            result += '| ' + o.Label + ' | `' + o.QualifiedApiName + '` |\n';
        return result;
    }

    // ── Installed packages ────────────────────────────────────────────────────
    private static String getInstalledPackages() {
        List<PackageLicense> pkgs = [
            SELECT AllowedLicenses, UsedLicenses, ExpirationDate, NamespacePrefix
            FROM PackageLicense ORDER BY NamespacePrefix
        ];
        if (pkgs.isEmpty()) return '📋 No installed managed packages found.';
        String result = '## 📦 Installed Packages (' + pkgs.size() + ')\n\n'
                      + '| Namespace | Used | Allowed | Expires |\n|---|---|---|---|\n';
        for (PackageLicense p : pkgs)
            result += '| `' + p.NamespacePrefix + '` | ' + p.UsedLicenses
                    + ' | ' + p.AllowedLicenses + ' | '
                    + (p.ExpirationDate != null ? String.valueOf(p.ExpirationDate) : 'Never') + ' |\n';
        return result;
    }

    // ── Flows ─────────────────────────────────────────────────────────────────
    private static String getFlows() {
        try {
            List<FlowDefinitionView> flows = [
                SELECT ApiName, Label, ProcessType, IsActive
                FROM FlowDefinitionView
                LIMIT 200
            ];

            if (flows.isEmpty()) return '📋 No flows found.';

            // Sort in Apex since ORDER BY can be unreliable on FlowDefinitionView
            flows.sort();

            String result = '## ⚡ Flows (' + flows.size() + ')\n\n'
                        + '| Label | API Name | Type | Active |\n|---|---|---|---|\n';
            for (FlowDefinitionView f : flows)
                result += '| **' + f.Label + '** | `' + f.ApiName + '` | '
                        + f.ProcessType + ' | ' + (f.IsActive ? '✅' : '❌') + ' |\n';
            return result;

        } catch (Exception e) {
            return '❌ Error fetching flows: ' + e.getMessage();
        }
    }

    // ── Flow (single detail) ───────────────────────────────────────────────
    private static String getFlowDetail(String prompt) {
        try {
            String searchName = extractQuotedOrKeywordValue(prompt);
            if (String.isBlank(searchName))
                return '❌ Please specify a flow name.\nExample: "Show details of flow MyFlow"';

            // FlowDefinitionView does NOT support OR in WHERE — run two queries
            List<FlowDefinitionView> byLabel = new List<FlowDefinitionView>();
            List<FlowDefinitionView> byApiName = new List<FlowDefinitionView>();

            try {
                byLabel = [
                    SELECT ApiName, Label, ProcessType, TriggerType,
                        IsActive, Description, LastModifiedDate
                    FROM FlowDefinitionView
                    WHERE Label LIKE :('%' + searchName + '%')
                    LIMIT 5
                ];
            } catch (Exception e1) { System.debug('byLabel query failed: ' + e1.getMessage()); }

            try {
                byApiName = [
                    SELECT ApiName, Label, ProcessType, TriggerType,
                        IsActive, Description, LastModifiedDate
                    FROM FlowDefinitionView
                    WHERE ApiName LIKE :('%' + searchName + '%')
                    LIMIT 5
                ];
            } catch (Exception e2) { System.debug('byApiName query failed: ' + e2.getMessage()); }

            // Deduplicate by ApiName
            Map<String, FlowDefinitionView> merged = new Map<String, FlowDefinitionView>();
            for (FlowDefinitionView f : byLabel)   { if (f != null && f.ApiName != null) merged.put(f.ApiName, f); }
            for (FlowDefinitionView f : byApiName) { if (f != null && f.ApiName != null) merged.put(f.ApiName, f); }

            if (merged.isEmpty())
                return '❌ No flow found matching **"' + searchName + '"**.\n\n'
                    + 'Try: "List all active flows" to see what\'s available.';

            List<FlowDefinitionView> results = new List<FlowDefinitionView>(merged.values());

            if (results.size() > 1) {
                String table = '## ⚡ Multiple Matches for "' + searchName + '"\n\n'
                            + '| Label | API Name | Active |\n|---|---|---|\n';
                for (FlowDefinitionView f : results) {
                    if (f == null) continue;
                    table += '| **' + (f.Label != null ? f.Label : '—') + '**'
                        + ' | `' + (f.ApiName != null ? f.ApiName : '—') + '`'
                        + ' | ' + (f.IsActive ? '✅' : '❌') + ' |\n';
                }
                table += '\n> Be more specific, e.g. "details of flow ' + results[0].Label + '"';
                return table;
            }

            FlowDefinitionView f = results[0];
            if (f == null) return '❌ Flow record is null. Please try again.';

            return '## ⚡ Flow Detail\n\n'
                + '| Field | Value |\n|---|---|\n'
                + '| **Label** | '         + (f.Label       != null ? f.Label       : '—') + ' |\n'
                + '| **API Name** | `'      + (f.ApiName     != null ? f.ApiName     : '—') + '` |\n'
                + '| **Process Type** | '  + (f.ProcessType != null ? f.ProcessType : '—') + ' |\n'
                + '| **Trigger Type** | '  + (f.TriggerType != null ? f.TriggerType : '—') + ' |\n'
                + '| **Active** | '        + (f.IsActive ? '✅ Yes' : '❌ No') + ' |\n'
                + '| **Description** | '   + (String.isNotBlank(f.Description) ? f.Description : '—') + ' |\n'
                + '| **Last Modified** | ' + (f.LastModifiedDate != null
                                            ? String.valueOf(f.LastModifiedDate).substring(0,10)
                                            : '—') + ' |\n';
        } catch (Exception e) {
            return '❌ Error fetching flow: ' + e.getMessage();
        }
    }

    // ── Apex classes ──────────────────────────────────────────────────────────
    private static String getApexClasses() {
        List<ApexClass> classes = [
            SELECT Id, Name, Status, IsValid, LastModifiedDate
            FROM ApexClass ORDER BY Name LIMIT 100
        ];
        String result = '## ⚙️ Apex Classes (' + classes.size() + ')\n\n'
                      + '| Name | Status | Valid | Last Modified |\n|---|---|---|---|\n';
        for (ApexClass c : classes)
            result += '| `' + c.Name + '` | ' + c.Status + ' | '
                    + (c.IsValid ? '✅' : '❌') + ' | '
                    + String.valueOf(c.LastModifiedDate).substring(0,10) + ' |\n';
        return result;
    }

    // Apex class (single detail) ─────────────────────────────────────────────
    private static String getApexClassDetail(String prompt) {
        try {
            String searchName = extractQuotedOrKeywordValue(prompt);
            if (String.isBlank(searchName))
                return '❌ Please specify a class name. Example:\n'
                    + '"Show details of Apex class SfAiAgentController"';

            List<ApexClass> results = [
                SELECT Id, Name, Status, IsValid, ApiVersion,
                    LengthWithoutComments, Body,
                    CreatedDate, LastModifiedDate,
                    CreatedBy.Name, LastModifiedBy.Name,
                    NamespacePrefix
                FROM ApexClass
                WHERE Name LIKE :('%' + searchName + '%')
                ORDER BY Name
                LIMIT 5
            ];

            if (results.isEmpty())
                return '❌ No Apex class found matching **"' + searchName + '"**.\n\n'
                    + 'Try: "List all Apex classes" to see what\'s available.';

            if (results.size() > 1) {
                String table = '## ⚙️ Multiple Matches for "' + searchName + '"\n\n'
                            + '| Name | Status | Valid |\n|---|---|---|\n';
                for (ApexClass c : results)
                    table += '| `' + c.Name + '` | ' + c.Status + ' | '
                        + (c.IsValid ? '✅' : '❌') + ' |\n';
                table += '\n> Be more specific, e.g. "details of Apex class ' + results[0].Name + '"';
                return table;
            }

            ApexClass c = results[0];

            // Count lines from body
            Integer lineCount = 0;
            if (String.isNotBlank(c.Body)) {
                lineCount = c.Body.split('\n').size();
            }

            return '## ⚙️ Apex Class Detail\n\n'
                + '| Field | Value |\n|---|---|\n'
                + '| **Name** | `'             + c.Name + '` |\n'
                + '| **Status** | '            + c.Status + ' |\n'
                + '| **Is Valid** | '          + (c.IsValid ? '✅ Yes' : '❌ No') + ' |\n'
                + '| **API Version** | '       + c.ApiVersion + ' |\n'
                + '| **Namespace** | '         + (String.isNotBlank(c.NamespacePrefix) ? '`' + c.NamespacePrefix + '`' : '— (no namespace)') + ' |\n'
                + '| **Lines of Code** | '     + lineCount + ' |\n'
                + '| **Chars (no comments)** | '+ c.LengthWithoutComments + ' |\n'
                + '| **Created Date** | '      + String.valueOf(c.CreatedDate).substring(0,10) + ' |\n'
                + '| **Created By** | '        + (c.CreatedBy != null ? c.CreatedBy.Name : '—') + ' |\n'
                + '| **Last Modified** | '     + String.valueOf(c.LastModifiedDate).substring(0,10) + ' |\n'
                + '| **Last Modified By** | '  + (c.LastModifiedBy != null ? c.LastModifiedBy.Name : '—') + ' |\n'
                + '| **Record ID** | `'         + c.Id + '` |\n';

        } catch (Exception e) {
            return '❌ Error fetching Apex class detail: ' + e.getMessage();
        }
    }

    // ── Validation rules ──────────────────────────────────────────────────────
    private static String getValidationRules(String prompt) {
        String objectName = extractObjectName(prompt);

        // ValidationRule is ONLY accessible via Tooling API — never via Database.query()
        // Always return the helpful instructions + ready-to-run Tooling API query
        String toolingQuery = 'SELECT Id, ValidationName, Active, ErrorMessage, '
                            + 'EntityDefinition.QualifiedApiName\n'
                            + 'FROM ValidationRule\n'
                            + (String.isNotBlank(objectName)
                            ? 'WHERE EntityDefinition.QualifiedApiName = \'' + objectName + '\'\n'
                            : '')
                            + 'ORDER BY ValidationName';

        return '## ✅ Validation Rules'
            + (String.isNotBlank(objectName) ? ' — `' + objectName + '`' : '') + '\n\n'
            + '> ⚠️ **Validation Rules require Tooling API** — they cannot be queried '
            + 'via standard SOQL in Apex.\n\n'
            + '### How to view them\n\n'
            + '**Option 1 — Setup UI (easiest):**\n'
            + 'Setup → Object Manager → **'
            + (String.isNotBlank(objectName) ? objectName : 'Your Object')
            + '** → Validation Rules\n\n'
            + '**Option 2 — Developer Console (Tooling API):**\n\n'
            + '1. Open **Developer Console**\n'
            + '2. Click **Query Editor** tab\n'
            + '3. ✅ Check **"Use Tooling API"** checkbox\n'
            + '4. Run this query:\n\n'
            + '```soql\n' + toolingQuery + '\n```\n\n'
            + '**Option 3 — REST API:**\n'
            + '```\n'
            + 'GET /services/data/v59.0/tooling/query/?q='
            + EncodingUtil.urlEncode(toolingQuery.replaceAll('\n', ' '), 'UTF-8')
            + '\n```';
    }

    // ── Record types ──────────────────────────────────────────────────────────
    private static String getRecordTypes(String prompt) {
        String objectName = extractObjectName(prompt);
        String soql = 'SELECT Id, Name, DeveloperName, SobjectType, IsActive FROM RecordType';
        if (String.isNotBlank(objectName))
            soql += ' WHERE SobjectType = \'' + String.escapeSingleQuotes(objectName) + '\'';
        soql += ' ORDER BY SobjectType, Name LIMIT 100';

        List<RecordType> rts = Database.query(soql);
        if (rts.isEmpty())
            return '📋 No record types found'
                 + (String.isNotBlank(objectName) ? ' for `' + objectName + '`' : '') + '.';

        String result = '## 📋 Record Types (' + rts.size() + ')\n\n'
                      + '| Name | API Name | Object | Active |\n|---|---|---|---|\n';
        for (RecordType rt : rts)
            result += '| **' + rt.Name + '** | `' + rt.DeveloperName + '` | '
                    + rt.SobjectType + ' | ' + (rt.IsActive ? '✅' : '❌') + ' |\n';
        return result;
    }

    // ── Active users ──────────────────────────────────────────────────────────
    private static String getActiveUsers() {
        List<User> users = [
            SELECT Id, Name, Username, Profile.Name, LastLoginDate
            FROM User WHERE IsActive = true ORDER BY Name LIMIT 50
        ];
        String result = '## 👥 Active Users (' + users.size() + ')\n\n'
                      + '| Name | Username | Profile | Last Login |\n|---|---|---|---|\n';
        for (User u : users)
            result += '| **' + u.Name + '** | `' + u.Username + '` | '
                    + (u.Profile != null ? u.Profile.Name : '—') + ' | '
                    + (u.LastLoginDate != null
                       ? String.valueOf(u.LastLoginDate).substring(0,10) : 'Never') + ' |\n';
        return result;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SOQL EXECUTION
    // ══════════════════════════════════════════════════════════════════════════

    // ── List of Tooling API-only objects that cannot be queried via Database.query()
    private static final Set<String> TOOLING_ONLY_OBJECTS = new Set<String>{
        'validationrule', 'workflowrule', 'workflowalert', 'workflowfieldupdate',
        'workflowtask', 'workflowsend', 'workflowoutboundmessage',
        'apextriggermetadata', 'customfield', 'customobject',
        'layoutassignment', 'permissionsetassignment',
        'profilelayout', 'weblink', 'businessprocess',
        'recordtype' // RecordType IS queryable but users sometimes use Tooling syntax
    };

    private static String executeSoqlAndFormat(String query) {
        try {
            String lower = query.trim().toLowerCase();

            // ── Guard: detect Tooling API objects in the query ─────────────────────
            for (String toolingObj : TOOLING_ONLY_OBJECTS) {
                // Check "FROM <object>" pattern
                if (lower.contains('from ' + toolingObj)) {
                    String objDisplay = toolingObj.substring(0,1).toUpperCase()
                                    + toolingObj.substring(1);
                    return '## ⚠️ Tooling API Object Detected\n\n'
                        + '`' + objDisplay + '` cannot be queried via standard SOQL in Apex.\n\n'
                        + '**To run this query:**\n\n'
                        + '1. Open **Developer Console**\n'
                        + '2. Click **Query Editor** tab\n'
                        + '3. ✅ Check **"Use Tooling API"** checkbox\n'
                        + '4. Paste and run:\n\n'
                        + '```soql\n' + query + '\n```\n\n'
                        + '**Or via REST API:**\n'
                        + '```\nGET /services/data/v59.0/tooling/query/?q='
                        + EncodingUtil.urlEncode(query.replaceAll('\n',' '), 'UTF-8')
                        + '\n```';
                }
            }

            // COUNT query
            if (lower.startsWith('select count(')) {
                Integer total = Database.countQuery(query);
                return '## 📊 Count Result\n\n```soql\n' + query + '\n```\n\n'
                    + '**Total Records:** ' + total;
            }

            // Detect subquery
            Boolean hasSubquery = query.indexOf('(') > 0
                && query.indexOf('(') < query.lastIndexOf(')')
                && lower.contains('select')
                && lower.indexOf('select') != lower.lastIndexOf('select');

            if (hasSubquery) return executeSubqueryAndFormat(query);

            // Standard flat query
            List<SObject> records = Database.query(query);

            if (records.isEmpty())
                return '## 🔍 No Records Found\n\n```soql\n' + query
                    + '\n```\n\n*No records matched your criteria.*';

            List<String> lines = new List<String>();
            lines.add('## 📋 Query Results\n\n```soql\n' + query + '\n```\n');
            lines.add('**Total: ' + records.size() + ' record(s)**\n');

            Map<String, Object> firstFields = records[0].getPopulatedFieldsAsMap();
            List<String> fieldNames = new List<String>(firstFields.keySet());

            String header = '| '; String sep = '|';
            for (String fn : fieldNames) { header += fn + ' | '; sep += '---|'; }
            lines.add(header); lines.add(sep);

            for (Integer i = 0; i < records.size(); i++) {
                String row = '| ';
                for (String fn : fieldNames)
                    row += formatFieldValue(records[i].get(fn)) + ' | ';
                lines.add(row);
            }

            return String.join(lines, '\n');
        } 
        
        catch (Exception e) {
            String errMsg = e.getMessage() != null ? e.getMessage() : 'Unknown error';

            // ── Tooling API object ─────────────────────────────────────────────────────
            if (errMsg.contains('is not supported')) {
                return '## ⚠️ Tooling API Object\n\n'
                    + '❌ ' + errMsg + '\n\n'
                    + 'This object requires **Tooling API** — not queryable via standard SOQL.\n\n'
                    + '**Run in Developer Console:**\n'
                    + '1. Open Developer Console → Query Editor\n'
                    + '2. ✅ Check **"Use Tooling API"**\n'
                    + '3. Run your query\n\n'
                    + '```soql\n' + query + '\n```';
            }

            // ── Invalid field on object ────────────────────────────────────────────────
            if (errMsg.contains('No such column') || errMsg.contains('no such column')) {
                // Extract the object name from the query to show its valid fields
                String objectName = extractObjectNameFromQuery(query);
                String fieldHelp  = '';

                if (String.isNotBlank(objectName)) {
                    try {
                        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
                        if (sot != null) {
                            Map<String, Schema.SObjectField> fields = sot.getDescribe().fields.getMap();
                            List<String> fieldNames = new List<String>(fields.keySet());
                            fieldNames.sort();

                            fieldHelp = '\n\n### ✅ Valid fields on `' + objectName + '`\n\n'
                                    + '| API Name | Label | Type |\n|---|---|---|\n';
                            for (String fn : fieldNames) {
                                Schema.DescribeFieldResult f = fields.get(fn).getDescribe();
                                fieldHelp += '| `' + f.getName() + '` | '
                                        + f.getLabel() + ' | '
                                        + f.getType() + ' |\n';
                            }
                        }
                    } catch (Exception describeEx) {
                        fieldHelp = '\n\n*Could not retrieve field list for `' + objectName + '`.*';
                    }
                }

                return '## ❌ Invalid Field\n\n'
                    + errMsg + '\n\n'
                    + '**Fix:** Check the field API name — it may be misspelled or not exist on this object.\n\n'
                    + '```soql\n' + query + '\n```'
                    + fieldHelp;
            }

            // ── Generic SOQL error ─────────────────────────────────────────────────────
            return '❌ **SOQL Error:** ' + errMsg
                + '\n\n```soql\n' + query + '\n```';
        }
    }

    private static String executeSubqueryAndFormat(String query) {
        try {
            List<SObject> parentRecords = Database.query(query);

            if (parentRecords.isEmpty())
                return '## 🔍 No Records Found\n\n```soql\n' + query
                    + '\n```\n\n*No parent records matched.*';

            List<String> lines = new List<String>();
            lines.add('## 📋 Query Results\n\n```soql\n' + query + '\n```\n');
            lines.add('**' + parentRecords.size() + ' parent record(s) found**\n');

            for (SObject parent : parentRecords) {
                Map<String, Object> parentFieldMap = parent.getPopulatedFieldsAsMap();

                // Parent field summary row
                String parentRow = '';
                for (String fn : parentFieldMap.keySet()) {
                    if (fn == 'attributes') continue;
                    try {
                        if (parentFieldMap.get(fn) instanceof List<SObject>) continue;
                        parentRow += '**' + fn + ':** `'
                                + formatFieldValue(parentFieldMap.get(fn)) + '`   ';
                    } catch (Exception skip) { continue; }
                }
                lines.add('### 🔹 ' + parentRow.trim());

                // Child records
                for (String fn : parentFieldMap.keySet()) {
                    Object rawVal = parentFieldMap.get(fn);
                    if (!(rawVal instanceof List<SObject>)) continue;

                    List<SObject> children = (List<SObject>) rawVal;
                    lines.add('\n**↳ ' + fn + '** — ' + children.size() + ' child record(s)\n');

                    if (children.isEmpty()) {
                        lines.add('*No child records found.*\n');
                        continue;
                    }

                    // Probe fields safely
                    Set<String> childFieldSet = children[0].getPopulatedFieldsAsMap().keySet();
                    List<String> childFields  = new List<String>();
                    for (String cf : childFieldSet) {
                        if (cf == 'attributes') continue;
                        try { Object probe = children[0].get(cf); childFields.add(cf); }
                        catch (SObjectException ex) { }
                    }

                    if (childFields.isEmpty()) {
                        lines.add('*Could not read child fields.*\n');
                        continue;
                    }

                    String hdr = '| '; String sep = '|';
                    for (String cf : childFields) { hdr += cf + ' | '; sep += '---|'; }
                    lines.add(hdr); lines.add(sep);

                    // Show ALL child records — no cap
                    for (Integer i = 0; i < children.size(); i++) {
                        String row = '| ';
                        for (String cf : childFields) {
                            String cv = '';
                            try { cv = formatFieldValue(children[i].get(cf)); }
                            catch (SObjectException ex) { cv = '—'; }
                            row += cv + ' | ';
                        }
                        lines.add(row);
                    }
                    lines.add('');
                }
                lines.add('\n---\n');
            }

            return String.join(lines, '\n');

        } catch (Exception e) {
            return '❌ **Subquery Error:** ' + e.getMessage()
                + '\n\n```soql\n' + query + '\n```\n\n'
                + '💡 Try running directly in Developer Console → Query Editor.';
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // OPENAI HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    private static String generateSoqlQuery(String prompt) {
        String sp = 'You are a Salesforce SOQL generator for STANDARD Apex Database.query(). '
                + 'IMPORTANT RULES:\n'
                + '1. Only generate queries for standard queryable SObjects.\n'
                + '2. NEVER generate queries for Tooling API objects such as: '
                + 'ValidationRule, WorkflowRule, CustomField, CustomObject, '
                + 'ApexTriggerMetadata, LayoutAssignment, ProfileLayout.\n'
                + '3. If the user asks for ValidationRule or any Tooling API object, '
                + 'reply with exactly: NO_QUERY\n'
                + '4. If the request asks for real Salesforce data from a standard object, '
                + 'reply ONLY with a valid SOQL SELECT query. '
                + 'No explanation, no markdown fences, no preamble.\n'
                + '5. If not asking for real data, reply with exactly: NO_QUERY';
        return stripCodeFences(callOpenAI(sp, prompt, 400, 0.0)).trim();
    }

    private static String callOpenAIChat(String prompt) {
        return callOpenAI(getSystemPrompt(), prompt, 1500, 0.2);
    }

    private static String callOpenAI(String systemPrompt, String userPrompt,
                                      Integer maxTokens, Decimal temperature) {
        List<Map<String, String>> msgs = new List<Map<String, String>>();
        msgs.add(new Map<String, String>{'role' => 'system', 'content' => systemPrompt});
        msgs.add(new Map<String, String>{'role' => 'user',   'content' => userPrompt});

        Map<String, Object> body = new Map<String, Object>();
        body.put('model',       'gpt-4o-mini');
        body.put('max_tokens',  maxTokens);
        body.put('temperature', temperature);
        body.put('messages',    msgs);

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:LLM_API/chat/completions');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer {!$Credential.LLM_External.apiKey}');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200)
            throw new AuraHandledException(
                'OpenAI error (' + res.getStatusCode() + '): ' + res.getBody());

        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices = (List<Object>) resp.get('choices');
        if (choices == null || choices.isEmpty())
            throw new AuraHandledException('No choices returned from OpenAI.');

        Map<String, Object> msg = (Map<String, Object>)
            ((Map<String, Object>) choices[0]).get('message');
        if (msg == null)
            throw new AuraHandledException('Null message block in OpenAI response.');

        return (String) msg.get('content');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════════════════════════

    private static Boolean containsObjectName(String lp) {
        return lp.contains('account')   || lp.contains('contact')     ||
               lp.contains('opportunity')|| lp.contains('lead')       ||
               lp.contains('case')      || lp.contains('task')        ||
               lp.contains('event')     || lp.contains('user')        ||
               lp.contains('contract')  || lp.contains('order')       ||
               lp.contains('product')   || lp.contains('asset')       ||
               lp.contains('campaign')  || lp.contains('quote')       ||
               lp.contains('__c');
    }

    private static String extractObjectName(String prompt) {
        String lp = prompt.toLowerCase();
        List<String> stdObjects = new List<String>{
            'account','contact','opportunity','lead','case','task','event',
            'user','contract','order','product2','asset','campaign','quote','pricebook2'
        };
        for (String o : stdObjects)
            if (lp.contains(o))
                return o.substring(0,1).toUpperCase() + o.substring(1);

        Pattern p = Pattern.compile('\\b([A-Za-z][A-Za-z0-9_]*__c)\\b');
        Matcher m = p.matcher(prompt);
        if (m.find()) return m.group(1);
        return null;
    }

    // ── Extract object name from a SOQL query string ──────────────────────────────
    private static String extractObjectNameFromQuery(String query) {
        if (String.isBlank(query)) return null;
        try {
            // Match "FROM ObjectName" — case insensitive
            Pattern p = Pattern.compile('(?i)\\bFROM\\s+([A-Za-z][A-Za-z0-9_]*)');
            Matcher m = p.matcher(query);
            if (m.find()) {
                String objName = m.group(1).trim();
                // Verify it exists in the org
                if (Schema.getGlobalDescribe().containsKey(objName)) {
                    return objName;
                }
                // Try capitalised version
                String cap = objName.substring(0,1).toUpperCase() + objName.substring(1);
                if (Schema.getGlobalDescribe().containsKey(cap)) return cap;
            }
        } catch (Exception e) {
            System.debug('extractObjectNameFromQuery error: ' + e.getMessage());
        }
        return null;
    }

    private static String extractFieldName(String prompt) {
        Pattern dotPat = Pattern.compile('[A-Za-z][A-Za-z0-9_]*\\.([A-Za-z][A-Za-z0-9_]*(?:__c)?)');
        Matcher dotM = dotPat.matcher(prompt);
        if (dotM.find()) return dotM.group(1);

        String lp = prompt.toLowerCase();
        for (String kw : new List<String>{
            'for field ','field ','picklist ','of field ','values of ','values for '
        }) {
            Integer idx = lp.indexOf(kw);
            if (idx >= 0) {
                String rest = prompt.substring(idx + kw.length()).trim()
                                    .split(' ')[0].replaceAll('[^A-Za-z0-9_]','');
                if (String.isNotBlank(rest)) return rest;
            }
        }
        return null;
    }

    private static String extractQuotedOrKeywordValue(String prompt) {
        // Quoted value first
        Pattern quoted = Pattern.compile('["\']([^"\']+)["\']');
        Matcher qm = quoted.matcher(prompt);
        if (qm.find()) return qm.group(1).trim();

        // Keyword patterns
        String lp = prompt.toLowerCase();
        List<String> keywords = new List<String>{
            'name equals ','name = ','named ','called ',
            'label equals ','label = ','detail of ','details of ',
            'detail for ','details for ','full detail of ',
            'full details of ','info on ','info about ',
            'having name ','group ','set '
        };
        for (String kw : keywords) {
            Integer idx = lp.indexOf(kw);
            if (idx >= 0) {
                String remainder = prompt.substring(idx + kw.length()).trim()
                                         .replaceAll('[?!.]$','').trim();
                if (String.isNotBlank(remainder)) return remainder;
            }
        }
        return null;
    }

    private static Boolean isValidSelectQuery(String q) {
        if (String.isBlank(q) || q.equalsIgnoreCase('NO_QUERY')) return false;
        String lower = q.trim().toLowerCase();
        if (!lower.startsWith('select ')) return false;
        for (String bad : new List<String>{
            ';',' delete ',' insert ',' update ',' upsert ',' merge '
        }) if (lower.contains(bad)) return false;
        return true;
    }

    private static String formatFieldValue(Object value) {
        if (value == null) return '';
        if (value instanceof DateTime) return ((DateTime) value).format('yyyy-MM-dd HH:mm');
        if (value instanceof Date)     return ((Date)     value).format();
        if (value instanceof Boolean)  return ((Boolean)  value) ? 'Yes' : 'No';
        String s = String.valueOf(value);
        return s.length() > 50 ? s.substring(0,47) + '...' : s;
    }

    private static String stripCodeFences(String text) {
        if (text == null) return '';
        String r = text.trim();
        if (r.startsWith('```')) {
            Integer last = r.lastIndexOf('```');
            if (last > 0) r = r.substring(r.indexOf('\n') + 1, last).trim();
        }
        return r;
    }

    private static String getSystemPrompt() {
        return 'You are an expert Salesforce AI Agent. Be concise and production-ready.\n'
             + 'Format ALL code in fenced blocks: ```apex ```soql ```javascript ```html\n'
             + 'Use Markdown tables for structured data.\n'
             + '**bold** for key terms. `backticks` for API names.\n'
             + 'Use bullet points and numbered steps where appropriate.';
    }
}