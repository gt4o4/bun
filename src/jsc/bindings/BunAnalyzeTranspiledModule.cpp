#include "root.h"

#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/JSModuleRecord.h"
#include "JavaScriptCore/GlobalObjectMethodTable.h"
#include "JavaScriptCore/Nodes.h"
#include "JavaScriptCore/Parser.h"
#include "JavaScriptCore/ParserError.h"
#include "JavaScriptCore/SyntheticModuleRecord.h"
#include <wtf/text/MakeString.h>
#include "JavaScriptCore/JSGlobalObject.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "ZigSourceProvider.h"
#include "ZigGlobalObject.h"
#include "headers-handwritten.h"
#include "IsolatedModuleCache.h"
#include "BunAnalyzeTranspiledModule.h"

// ref: JSModuleLoader.cpp
// ref: ModuleAnalyzer.cpp
// ref: JSModuleRecord.cpp
// ref: NodesAnalyzeModule.cpp, search ::analyzeModule

#include "JavaScriptCore/ModuleAnalyzer.h"
#include "JavaScriptCore/ErrorType.h"
#include "JavaScriptCore/ScriptFetchParameters.h"
#include "JavaScriptCore/TopExceptionScope.h"
#include "JavaScriptCore/Strong.h"
#include "JavaScriptCore/StrongInlines.h"
#include <limits>

namespace JSC {

String dumpRecordInfo(JSModuleRecord* moduleRecord);

Identifier getFromIdentifierArray(VM& vm, Identifier* identifierArray, uint32_t n)
{
    if (n == std::numeric_limits<uint32_t>::max()) {
        return vm.propertyNames->starDefaultPrivateName;
    }
    if (n == std::numeric_limits<uint32_t>::max() - 1) {
        return vm.propertyNames->starNamespacePrivateName;
    }
    return identifierArray[n];
}

extern "C" JSModuleRecord* zig__ModuleInfoDeserialized__toJSModuleRecord(JSGlobalObject* globalObject, VM& vm, const Identifier& module_key, const SourceCode& source_code, VariableEnvironment& declared_variables, VariableEnvironment& lexical_variables, bun_ModuleInfoDeserialized* module_info);
extern "C" void zig__renderDiff(const char* expected_ptr, size_t expected_len, const char* received_ptr, size_t received_len, JSGlobalObject* globalObject);

extern "C" Identifier* JSC__IdentifierArray__create(size_t len)
{
    return new Identifier[len];
}
extern "C" void JSC__IdentifierArray__destroy(Identifier* identifier)
{
    delete[] identifier;
}
extern "C" void JSC__IdentifierArray__setFromUtf8(Identifier* identifierArray, size_t n, VM& vm, char* str, size_t len)
{
    identifierArray[n] = Identifier::fromString(vm, AtomString::fromUTF8(std::span<const char>(str, len)));
}

extern "C" void JSC__VariableEnvironment__add(VariableEnvironment& environment, VM& vm, Identifier* identifierArray, uint32_t index)
{
    environment.add(getFromIdentifierArray(vm, identifierArray, index));
}

extern "C" VariableEnvironment* JSC_JSModuleRecord__declaredVariables(JSModuleRecord* moduleRecord)
{
    return const_cast<VariableEnvironment*>(&moduleRecord->declaredVariables());
}
extern "C" VariableEnvironment* JSC_JSModuleRecord__lexicalVariables(JSModuleRecord* moduleRecord)
{
    return const_cast<VariableEnvironment*>(&moduleRecord->lexicalVariables());
}

extern "C" JSModuleRecord* JSC_JSModuleRecord__create(JSGlobalObject* globalObject, VM& vm, const Identifier* moduleKey, const SourceCode& sourceCode, const VariableEnvironment& declaredVariables, const VariableEnvironment& lexicalVariables, bool hasImportMeta, bool isTypescript, bool hasTLA)
{
    JSModuleRecord* result = JSModuleRecord::create(globalObject, vm, globalObject->moduleRecordStructure(), *moduleKey, sourceCode, declaredVariables, lexicalVariables, hasImportMeta ? ImportMetaFeature : 0);
    result->m_isTypeScript = isTypescript;
    result->setHasTLA(hasTLA);
    return result;
}

extern "C" void JSC_JSModuleRecord__addIndirectExport(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t exportName, uint32_t importName, uint32_t moduleName)
{
    moduleRecord->addExportEntry(JSModuleRecord::ExportEntry::createIndirect(getFromIdentifierArray(moduleRecord->vm(), identifierArray, exportName), getFromIdentifierArray(moduleRecord->vm(), identifierArray, importName), getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName)));
}
extern "C" void JSC_JSModuleRecord__addLocalExport(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t exportName, uint32_t localName)
{
    moduleRecord->addExportEntry(JSModuleRecord::ExportEntry::createLocal(getFromIdentifierArray(moduleRecord->vm(), identifierArray, exportName), getFromIdentifierArray(moduleRecord->vm(), identifierArray, localName)));
}
extern "C" void JSC_JSModuleRecord__addNamespaceExport(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t exportName, uint32_t moduleName)
{
    moduleRecord->addExportEntry(JSModuleRecord::ExportEntry::createNamespace(getFromIdentifierArray(moduleRecord->vm(), identifierArray, exportName), getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName)));
}
extern "C" void JSC_JSModuleRecord__addStarExport(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t moduleName)
{
    moduleRecord->addStarExportEntry(getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName));
}
extern "C" void JSC_JSModuleRecord__addRequestedModuleNullAttributesPtr(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t moduleName)
{
    RefPtr<ScriptFetchParameters> attributes = RefPtr<ScriptFetchParameters> {};
    moduleRecord->appendRequestedModule(getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName), std::move(attributes));
}
extern "C" void JSC_JSModuleRecord__addRequestedModuleJavaScript(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t moduleName)
{
    Ref<ScriptFetchParameters> attributes = ScriptFetchParameters::create(ScriptFetchParameters::Type::JavaScript);
    moduleRecord->appendRequestedModule(getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName), std::move(attributes));
}
extern "C" void JSC_JSModuleRecord__addRequestedModuleWebAssembly(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t moduleName)
{
    Ref<ScriptFetchParameters> attributes = ScriptFetchParameters::create(ScriptFetchParameters::Type::WebAssembly);
    moduleRecord->appendRequestedModule(getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName), std::move(attributes));
}
extern "C" void JSC_JSModuleRecord__addRequestedModuleJSON(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t moduleName)
{
    Ref<ScriptFetchParameters> attributes = ScriptFetchParameters::create(ScriptFetchParameters::Type::JSON);
    moduleRecord->appendRequestedModule(getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName), std::move(attributes));
}
extern "C" void JSC_JSModuleRecord__addRequestedModuleHostDefined(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t moduleName, uint32_t hostDefinedImportType)
{
    Ref<ScriptFetchParameters> attributes = ScriptFetchParameters::create(getFromIdentifierArray(moduleRecord->vm(), identifierArray, hostDefinedImportType).string());
    moduleRecord->appendRequestedModule(getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName), std::move(attributes));
}

extern "C" void JSC_JSModuleRecord__addImportEntrySingle(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t importName, uint32_t localName, uint32_t moduleName)
{
    moduleRecord->addImportEntry(JSModuleRecord::ImportEntry {
        .type = JSModuleRecord::ImportEntryType::Single,
        .moduleRequest = getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName),
        .importName = getFromIdentifierArray(moduleRecord->vm(), identifierArray, importName),
        .localName = getFromIdentifierArray(moduleRecord->vm(), identifierArray, localName),
    });
}
extern "C" void JSC_JSModuleRecord__addImportEntrySingleTypeScript(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t importName, uint32_t localName, uint32_t moduleName)
{
    moduleRecord->addImportEntry(JSModuleRecord::ImportEntry {
        .type = JSModuleRecord::ImportEntryType::SingleTypeScript,
        .moduleRequest = getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName),
        .importName = getFromIdentifierArray(moduleRecord->vm(), identifierArray, importName),
        .localName = getFromIdentifierArray(moduleRecord->vm(), identifierArray, localName),
    });
}
extern "C" void JSC_JSModuleRecord__addImportEntryNamespace(JSModuleRecord* moduleRecord, Identifier* identifierArray, uint32_t importName, uint32_t localName, uint32_t moduleName)
{
    moduleRecord->addImportEntry(JSModuleRecord::ImportEntry {
        .type = JSModuleRecord::ImportEntryType::Namespace,
        .moduleRequest = getFromIdentifierArray(moduleRecord->vm(), identifierArray, moduleName),
        .importName = getFromIdentifierArray(moduleRecord->vm(), identifierArray, importName),
        .localName = getFromIdentifierArray(moduleRecord->vm(), identifierArray, localName),
    });
}

static EncodedJSValue fallbackParse(JSGlobalObject* globalObject, const Identifier& moduleKey, const SourceCode& sourceCode, JSPromise* promise, JSModuleRecord* resultValue = nullptr);
extern "C" EncodedJSValue Bun__analyzeTranspiledModule(JSGlobalObject* globalObject, const Identifier& moduleKey, const SourceCode& sourceCode, JSPromise* promise)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto rejectWithError = [&](JSValue error) {
        promise->reject(vm, globalObject, error);
        return promise;
    };

    VariableEnvironment declaredVariables = VariableEnvironment();
    VariableEnvironment lexicalVariables = VariableEnvironment();

    auto provider = static_cast<Zig::SourceProvider*>(sourceCode.provider());

    if (provider->m_resolvedSource.module_info == nullptr) {
        dataLog("[note] module_info is null for module: ", moduleKey.utf8(), "\n");
        RELEASE_AND_RETURN(scope, JSValue::encode(rejectWithError(createError(globalObject, WTF::String::fromLatin1("module_info is null")))));
    }

    auto* moduleInfo = static_cast<bun_ModuleInfoDeserialized*>(provider->m_resolvedSource.module_info);
    auto moduleRecord = zig__ModuleInfoDeserialized__toJSModuleRecord(globalObject, vm, moduleKey, sourceCode, declaredVariables, lexicalVariables, moduleInfo);
    // Under --isolate the same SourceProvider is reused across globals via the
    // IsolatedModuleCache, so module_info must remain alive on the provider;
    // ~SourceProvider frees it. Otherwise, free now.
    if (!Bun::IsolatedModuleCache::canUse(vm, uncheckedDowncast<Zig::GlobalObject>(globalObject)->bunVM())) {
        zig__ModuleInfoDeserialized__deinit(moduleInfo);
        provider->m_resolvedSource.module_info = nullptr;
    }
    if (moduleRecord == nullptr) {
        RELEASE_AND_RETURN(scope, JSValue::encode(rejectWithError(createError(globalObject, WTF::String::fromLatin1("parseFromSourceCode failed")))));
    }

#if BUN_DEBUG
    RELEASE_AND_RETURN(scope, fallbackParse(globalObject, moduleKey, sourceCode, promise, moduleRecord));
#else
    promise->resolve(globalObject, vm, moduleRecord);
    RELEASE_AND_RETURN(scope, JSValue::encode(promise));
#endif
}
static EncodedJSValue fallbackParse(JSGlobalObject* globalObject, const Identifier& moduleKey, const SourceCode& sourceCode, JSPromise* promise, JSModuleRecord* resultValue)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto rejectWithError = [&](JSValue error) {
        promise->reject(vm, globalObject, error);
        return promise;
    };

    ParserError error;
    std::unique_ptr<ModuleProgramNode> moduleProgramNode = parseRootNode<ModuleProgramNode>(
        vm, sourceCode, ImplementationVisibility::Public, JSParserBuiltinMode::NotBuiltin,
        StrictModeLexicallyScopedFeature, JSParserScriptMode::Module, SourceParseMode::ModuleAnalyzeMode, error);
    if (error.isValid())
        RELEASE_AND_RETURN(scope, JSValue::encode(rejectWithError(error.toErrorObject(globalObject, sourceCode))));
    ASSERT(moduleProgramNode);

    ModuleAnalyzer moduleAnalyzer(globalObject, moduleKey, sourceCode, moduleProgramNode->varDeclarations(), moduleProgramNode->lexicalVariables(), moduleProgramNode->features());
    RETURN_IF_EXCEPTION(scope, JSValue::encode(promise->rejectWithCaughtException(globalObject, scope)));

    auto result = moduleAnalyzer.analyze(*moduleProgramNode);
    if (!result) {
        auto [errorType, message] = std::move(result.error());
        RELEASE_AND_RETURN(scope, JSValue::encode(rejectWithError(createError(globalObject, errorType, message))));
    }

    JSModuleRecord* moduleRecord = result.value();

    if (resultValue != nullptr) {
        auto actual = dumpRecordInfo(resultValue);
        auto expected = dumpRecordInfo(moduleRecord);
        if (actual != expected) {
            dataLog("\n\n\n\n\n\n\x1b[95mBEGIN analyzeTranspiledModule\x1b(B\x1b[m\n  --- module key ---\n", moduleKey.utf8().data(), "\n  --- code ---\n\n", sourceCode.toUTF8().data(), "\n");
            dataLog("  ------", "\n");
            dataLog("  BunAnalyzeTranspiledModule:", "\n");

            zig__renderDiff(expected.utf8().data(), expected.utf8().length(), actual.utf8().data(), actual.utf8().length(), globalObject);

            RELEASE_AND_RETURN(scope, JSValue::encode(rejectWithError(createError(globalObject, WTF::String::fromLatin1("Imports different between parseFromSourceCode and fallbackParse")))));
        }
    }

    scope.release();
    promise->resolve(globalObject, vm, resultValue == nullptr ? moduleRecord : resultValue);
    return JSValue::encode(promise);
}

String dumpRecordInfo(JSModuleRecord* moduleRecord)
{
    WTF::StringPrintStream stream;

    {
        Vector<String> sortedVars;
        for (const auto& pair : moduleRecord->declaredVariables())
            sortedVars.append(String(pair.key.get()));
        std::sort(sortedVars.begin(), sortedVars.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        stream.print("  varDeclarations:\n");
        for (const auto& name : sortedVars)
            stream.print("  - ", name, "\n");
    }

    {
        Vector<String> sortedVars;
        for (const auto& pair : moduleRecord->lexicalVariables())
            sortedVars.append(String(pair.key.get()));
        std::sort(sortedVars.begin(), sortedVars.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        stream.print("  lexicalVariables:\n");
        for (const auto& name : sortedVars)
            stream.print("  - ", name, "\n");
    }

    stream.print("  features: (not accessible)\n");

    stream.print("\nAnalyzing ModuleRecord key(", moduleRecord->moduleKey().impl(), ")\n");

    stream.print("    Dependencies: ", moduleRecord->requestedModules().size(), " modules\n");
    {
        Vector<String> sortedDeps;
        for (const auto& request : moduleRecord->requestedModules()) {
            WTF::StringPrintStream line;
            if (request.m_attributes == nullptr)
                line.print("      module(", request.m_specifier, ")\n");
            else
                line.print("      module(", request.m_specifier, "),attributes(", (uint8_t)request.m_attributes->type(), ", ", request.m_attributes->hostDefinedImportType(), ")\n");
            sortedDeps.append(line.toString());
        }
        std::sort(sortedDeps.begin(), sortedDeps.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        for (const auto& dep : sortedDeps)
            stream.print(dep);
    }

    stream.print("    Import: ", moduleRecord->importEntries().size(), " entries\n");
    {
        Vector<String> sortedImports;
        for (const auto& pair : moduleRecord->importEntries()) {
            WTF::StringPrintStream line;
            auto& importEntry = pair.value;
            line.print("      import(", importEntry.importName, "), local(", importEntry.localName, "), module(", importEntry.moduleRequest, ")\n");
            sortedImports.append(line.toString());
        }
        std::sort(sortedImports.begin(), sortedImports.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        for (const auto& imp : sortedImports)
            stream.print(imp);
    }

    stream.print("    Export: ", moduleRecord->exportEntries().size(), " entries\n");
    Vector<String> sortedEntries;
    for (const auto& pair : moduleRecord->exportEntries()) {
        WTF::StringPrintStream line;
        auto& exportEntry = pair.value;
        switch (exportEntry.type) {
        case AbstractModuleRecord::ExportEntry::Type::Local:
            line.print("      [Local] ", "export(", exportEntry.exportName, "), local(", exportEntry.localName, ")\n");
            break;

        case AbstractModuleRecord::ExportEntry::Type::Indirect:
            line.print("      [Indirect] ", "export(", exportEntry.exportName, "), import(", exportEntry.importName, "), module(", exportEntry.moduleName, ")\n");
            break;

        case AbstractModuleRecord::ExportEntry::Type::Namespace:
            line.print("      [Namespace] ", "export(", exportEntry.exportName, "), module(", exportEntry.moduleName, ")\n");
            break;
        }
        sortedEntries.append(line.toString());
    }
    std::sort(sortedEntries.begin(), sortedEntries.end(), [](const String& a, const String& b) {
        return codePointCompare(a, b) < 0;
    });
    for (const auto& entry : sortedEntries)
        stream.print(entry);

    {
        Vector<String> sortedStarExports;
        for (const auto& moduleName : moduleRecord->starExportEntries()) {
            WTF::StringPrintStream line;
            line.print("      [Star] module(", moduleName.get(), ")\n");
            sortedStarExports.append(line.toString());
        }
        std::sort(sortedStarExports.begin(), sortedStarExports.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        for (const auto& entry : sortedStarExports)
            stream.print(entry);
    }

    stream.print("  -> done\n");

    return stream.toString();
}

}

// ── module_info for pre-built ESM (`bun build --already-bundled --format=esm`) ──
// JSC parses and analyzes the verbatim source on the bytecode-cache VM, and the
// resulting JSModuleRecord is handed to Zig's ModuleInfo builder field by field
// (the inverse of zig__ModuleInfoDeserialized__toJSModuleRecord above).  The
// sidecar is therefore exactly the record the runtime would otherwise derive by
// parsing, which is what lets a BunTranspiledModule provider skip that parse.
struct bun_ModuleInfo;
extern "C" bun_ModuleInfo* zig__ModuleInfo__create(bool isTypeScript);
extern "C" uint32_t zig__ModuleInfo__str(bun_ModuleInfo*, const char* ptr, size_t len);
extern "C" void zig__ModuleInfo__addDeclaredVariable(bun_ModuleInfo*, uint32_t id);
extern "C" void zig__ModuleInfo__addLexicalVariable(bun_ModuleInfo*, uint32_t id);
extern "C" void zig__ModuleInfo__addImportInfoSingle(bun_ModuleInfo*, uint32_t moduleName, uint32_t importName, uint32_t localName, bool onlyUsedAsType);
extern "C" void zig__ModuleInfo__addImportInfoNamespace(bun_ModuleInfo*, uint32_t moduleName, uint32_t localName);
extern "C" void zig__ModuleInfo__addExportInfoIndirect(bun_ModuleInfo*, uint32_t exportName, uint32_t importName, uint32_t moduleName);
extern "C" void zig__ModuleInfo__addExportInfoLocal(bun_ModuleInfo*, uint32_t exportName, uint32_t localName);
extern "C" void zig__ModuleInfo__addExportInfoNamespace(bun_ModuleInfo*, uint32_t exportName, uint32_t moduleName);
extern "C" void zig__ModuleInfo__addExportInfoStar(bun_ModuleInfo*, uint32_t moduleName);
extern "C" void zig__ModuleInfo__requestModule(bun_ModuleInfo*, uint32_t moduleName, uint32_t fetchParameters);
extern "C" void zig__ModuleInfo__setFlags(bun_ModuleInfo*, bool containsImportMeta, bool hasTLA);
extern "C" JSC::VM* Bun__vmForBytecodeCache();

extern "C" bun_ModuleInfo* Bun__generateModuleInfoFromSourceCode(BunString* sourceProviderURL, const Latin1Character* inputSourceCode, size_t inputSourceCodeSize)
{
    using namespace JSC;
    VM& vm = *Bun__vmForBytecodeCache();
    JSLockHolder locker(vm);

    // A bare JSGlobalObject suffices: ModuleAnalyzer only needs
    // moduleRecordStructure() and the VM's private names.  One per thread,
    // like the VM it lives in.
    static thread_local Strong<JSGlobalObject> analysisGlobal;
    if (!analysisGlobal)
        analysisGlobal.set(vm, JSGlobalObject::create(vm, JSGlobalObject::createStructure(vm, jsNull())));
    JSGlobalObject* globalObject = analysisGlobal.get();

    WTF::String url = sourceProviderURL->toWTFString();
    std::span<const Latin1Character> sourceCodeSpan(inputSourceCode, inputSourceCodeSize);
    SourceCode sourceCode = makeSource(WTF::String(sourceCodeSpan), SourceOrigin(WTF::URL::fileURLWithFileSystemPath(url)), SourceTaintedOrigin::Untainted);

    ParserError error;
    std::unique_ptr<ModuleProgramNode> moduleProgramNode = parseRootNode<ModuleProgramNode>(
        vm, sourceCode, ImplementationVisibility::Public, JSParserBuiltinMode::NotBuiltin,
        StrictModeLexicallyScopedFeature, JSParserScriptMode::Module, SourceParseMode::ModuleAnalyzeMode, error);
    if (error.isValid() || !moduleProgramNode)
        return nullptr;

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    Identifier moduleKey = Identifier::fromString(vm, url);
    ModuleAnalyzer moduleAnalyzer(globalObject, moduleKey, sourceCode, moduleProgramNode->varDeclarations(), moduleProgramNode->lexicalVariables(), moduleProgramNode->features());
    if (scope.exception()) {
        scope.clearException();
        return nullptr;
    }
    auto result = moduleAnalyzer.analyze(*moduleProgramNode);
    if (scope.exception()) {
        scope.clearException();
        return nullptr;
    }
    if (!result)
        return nullptr;
    JSModuleRecord* record = result.value();

    bun_ModuleInfo* mi = zig__ModuleInfo__create(false);
    if (!mi)
        return nullptr;
    auto id = [&](const Identifier& ident) -> uint32_t {
        // StringID's sentinels (analyze_transpiled_module.zig) for the two
        // private names JSC uses for `export default` and namespace imports.
        if (ident == vm.propertyNames->starDefaultPrivateName)
            return std::numeric_limits<uint32_t>::max();
        if (ident == vm.propertyNames->starNamespacePrivateName)
            return std::numeric_limits<uint32_t>::max() - 1;
        auto utf8 = ident.string().string().utf8();
        return zig__ModuleInfo__str(mi, utf8.data(), utf8.length());
    };
    auto uidId = [&](UniquedStringImpl* uid) -> uint32_t { return id(Identifier::fromUid(vm, uid)); };

    for (const auto& pair : record->declaredVariables())
        zig__ModuleInfo__addDeclaredVariable(mi, uidId(pair.key.get()));
    for (const auto& pair : record->lexicalVariables())
        zig__ModuleInfo__addLexicalVariable(mi, uidId(pair.key.get()));

    // Requested modules keep source order (Vector).  FetchParameters mirror
    // ModuleInfo.FetchParameters' encoding: none / javascript / webassembly /
    // json are the top sentinels, host-defined is a StringID.
    for (const auto& request : record->requestedModules()) {
        uint32_t fetch = std::numeric_limits<uint32_t>::max();
        if (request.m_attributes) {
            switch (request.m_attributes->type()) {
            case ScriptFetchParameters::Type::None:
                break;
            case ScriptFetchParameters::Type::JavaScript:
                fetch = std::numeric_limits<uint32_t>::max() - 1;
                break;
            case ScriptFetchParameters::Type::WebAssembly:
                fetch = std::numeric_limits<uint32_t>::max() - 2;
                break;
            case ScriptFetchParameters::Type::JSON:
                fetch = std::numeric_limits<uint32_t>::max() - 3;
                break;
            case ScriptFetchParameters::Type::HostDefined: {
                auto utf8 = request.m_attributes->hostDefinedImportType().utf8();
                fetch = zig__ModuleInfo__str(mi, utf8.data(), utf8.length());
                break;
            }
            }
        }
        zig__ModuleInfo__requestModule(mi, id(request.m_specifier), fetch);
    }

    for (const auto& pair : record->importEntries()) {
        const auto& entry = pair.value;
        switch (entry.type) {
        case AbstractModuleRecord::ImportEntryType::Single:
            zig__ModuleInfo__addImportInfoSingle(mi, id(entry.moduleRequest), id(entry.importName), id(entry.localName), false);
            break;
        case AbstractModuleRecord::ImportEntryType::SingleTypeScript:
            zig__ModuleInfo__addImportInfoSingle(mi, id(entry.moduleRequest), id(entry.importName), id(entry.localName), true);
            break;
        case AbstractModuleRecord::ImportEntryType::Namespace:
            zig__ModuleInfo__addImportInfoNamespace(mi, id(entry.moduleRequest), id(entry.localName));
            break;
        }
    }

    for (const auto& pair : record->exportEntries()) {
        const auto& entry = pair.value;
        switch (entry.type) {
        case AbstractModuleRecord::ExportEntry::Type::Local:
            zig__ModuleInfo__addExportInfoLocal(mi, id(entry.exportName), id(entry.localName));
            break;
        case AbstractModuleRecord::ExportEntry::Type::Indirect:
            zig__ModuleInfo__addExportInfoIndirect(mi, id(entry.exportName), id(entry.importName), id(entry.moduleName));
            break;
        case AbstractModuleRecord::ExportEntry::Type::Namespace:
            zig__ModuleInfo__addExportInfoNamespace(mi, id(entry.exportName), id(entry.moduleName));
            break;
        }
    }
    for (const auto& moduleName : record->starExportEntries())
        zig__ModuleInfo__addExportInfoStar(mi, uidId(moduleName.get()));

    zig__ModuleInfo__setFlags(mi, (moduleProgramNode->features() & ImportMetaFeature) != 0, moduleProgramNode->usesAwait());
    return mi;
}
