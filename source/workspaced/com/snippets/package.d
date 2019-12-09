module workspaced.com.snippets;

import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import workspaced.api;
import workspaced.com.dfmt : DfmtComponent;
import workspaced.com.snippets.generator;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.json;
import std.string;

public import workspaced.com.snippets.plain;
public import workspaced.com.snippets.smart;
public import workspaced.com.snippets.dependencies;

/// Component for auto completing snippets with context information and formatting these snippets with dfmt.
@component("snippets")
class SnippetsComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	static PlainSnippetProvider plainSnippets;
	static SmartSnippetProvider smartSnippets;
	static DependencyBasedSnippetProvider dependencySnippets;

	protected SnippetProvider[] providers;

	protected void load()
	{
		config.stringBehavior = StringBehavior.source;
		providers.reserve(16);
		providers ~= plainSnippets = new PlainSnippetProvider();
		providers ~= smartSnippets = new SmartSnippetProvider();
		providers ~= dependencySnippets = new DependencyBasedSnippetProvider();
	}

	/** 
	 * Params:
	 *   file = Filename to resolve dependencies relatively from.
	 *   code = Code to complete snippet in.
	 *   position = Byte offset of where to find scope in.
	 *
	 * Returns: a `SnippetInfo` object for all snippet information.
	 *
	 * `.loopScope` is set if a loop can be inserted at this position, Optionally
	 * with information about close ranges. Contains `SnippetLoopScope.init` if
	 * this is not a location where a loop can be inserted.
	 */
	SnippetInfo determineSnippetInfo(scope const(char)[] file, scope const(char)[] code, int position)
	{
		// each variable is 1
		// maybe more expensive lookups with DCD in the future
		enum LoopVariableAnalyzeMaxCost = 90;

		scope tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		// TODO: binary search
		size_t loc;
		foreach (i, tok; tokens)
			if (tok.index >= position)
			{
				loc = i;
				break;
			}

		auto leading = tokens[0 .. loc];
		foreach_reverse (t; leading)
		{
			if (t.type == tok!";")
				break;

			// test for tokens semicolon closed statements where we should abort to avoid incomplete syntax
			if (t.type.among!(tok!"import", tok!"module"))
			{
				return SnippetInfo([SnippetLevel.global, SnippetLevel.other]);
			}
			else if (t.type.among!(tok!"=", tok!"+", tok!"-", tok!"*", tok!"/",
					tok!"%", tok!"^^", tok!"&", tok!"|", tok!"^", tok!"<<",
					tok!">>", tok!">>>", tok!"~", tok!"in"))
			{
				return SnippetInfo([SnippetLevel.global, SnippetLevel.value]);
			}
		}

		scope parsed = parseModule(tokens, cast(string) file, &rba);

		trace("determineSnippetInfo at ", position);

		scope gen = new SnippetInfoGenerator(position);
		gen.variableStack.reserve(64);
		gen.visit(parsed);

		gen.value.loopScope.supported = gen.value.level == SnippetLevel.method;
		if (gen.value.loopScope.supported)
		{
			int cost = 0;
			foreach_reverse (v; gen.variableStack)
			{
				if (fillLoopScopeInfo(gen.value.loopScope, v))
					break;
				if (++cost > LoopVariableAnalyzeMaxCost)
					break;
			}
		}

		return gen.value;
	}

	Future!(Snippet[]) getSnippets(scope const(char)[] file, scope const(char)[] code, int position)
	{
		mixin(gthreadsAsyncProxy!`getSnippetsBlocking(file, code, position)`);
	}

	Snippet[] getSnippetsBlocking(scope const(char)[] file, scope const(char)[] code, int position)
	{
		auto futures = collectSnippets(file, code, position);

		auto ret = appender!(Snippet[]);
		foreach (fut; futures)
			ret.put(fut.getBlocking());
		return ret.data;
	}

	Snippet[] getSnippetsYield(scope const(char)[] file, scope const(char)[] code, int position)
	{
		auto futures = collectSnippets(file, code, position);

		auto ret = appender!(Snippet[]);
		foreach (fut; futures)
			ret.put(fut.getYield());
		return ret.data;
	}

	Future!Snippet resolveSnippet(scope const(char)[] file, scope const(char)[] code,
			int position, Snippet snippet)
	{
		foreach (provider; providers)
		{
			if (typeid(provider).name == snippet.providerId)
			{
				const info = determineSnippetInfo(file, code, position);
				return provider.resolveSnippet(instance, file, code, position, info, snippet);
			}
		}

		return Future!Snippet.fromResult(snippet);
	}

	Future!string format(scope const(char)[] snippet, string[] arguments = [])
	{
		mixin(gthreadsAsyncProxy!`formatSync(snippet, arguments)`);
	}

	/// Will format the code passed in synchronously using dfmt. Might take a short moment on larger documents.
	/// Returns: the formatted code as string or unchanged if dfmt is not active
	string formatSync(scope const(char)[] snippet, string[] arguments = [])
	{
		if (!has!DfmtComponent)
			return snippet.idup;

		auto dfmt = get!DfmtComponent;

		auto tmp = appender!string;

		scope const(char)[][string] tokens;

		ptrdiff_t dollar, last;
		while (true)
		{
			dollar = snippet.indexOfAny(`$\`, last);
			if (dollar == -1)
			{
				tmp ~= snippet[last .. $];
				break;
			}

			tmp ~= snippet[last .. dollar];
			last = dollar + 1;
			if (last >= snippet.length)
				break;
			if (snippet[dollar] == '\\')
			{
				tmp ~= snippet[dollar + 1];
				last = dollar + 2;
			}
			else
			{
				string key = "__WspD_Snp_" ~ dollar.to!string;
				const(char)[] str;

				if (snippet[dollar + 1] == '{')
				{
					ptrdiff_t i = dollar + 2;
					int depth = 1;
					while (true)
					{
						auto next = snippet.indexOfAny(`\{}`, i);
						if (next == -1)
						{
							i = snippet.length;
							break;
						}

						if (snippet[next] == '\\')
							i = next + 2;
						else
						{
							if (snippet[next] == '{')
								depth++;
							else if (snippet[next] == '}')
								depth--;
							else
								assert(false);

							i = next + 1;
						}

						if (depth == 0)
							break;
					}
					str = snippet[dollar .. i];
					last = i;

					if (str.length > 5 || snippet[last .. $].stripLeft.startsWith(";", ".", "{"))
					{
						// let's insert some token in here instead of a comment because there is probably some default content
						if (str[0 .. $ - 1].endsWith(';'))
							key ~= ';';
					}
					else
					{
						// empty default, put in comment
						key = "/+++" ~ key ~ "+++/";
					}
				}
				else
				{
					size_t end = dollar + 1;

					if (snippet[dollar + 1].isDigit)
					{
						while (end < snippet.length && snippet[end].isDigit)
							end++;
					}
					else
					{
						while (end < snippet.length && (snippet[end].isAlphaNum || snippet[end] == '_'))
							end++;
					}

					str = snippet[dollar .. end];
					last = end;
					if (snippet[last .. $].stripLeft.startsWith(";", ".", "{"))
					{
						// keep value thing as token
					}
					else
					{
						// primitive placeholder as comment
						key = "/+++" ~ key ~ "+++/";
					}
				}

				tokens[key] = str;
				tmp ~= key;
			}
		}

		auto res = dfmt.formatSync(tmp.data, arguments);

		foreach (key, value; tokens)
		{
			// TODO: replacing using aho-corasick would be far more efficient but there is nothing like that in phobos
			res = res.replace(key, value);
		}

		if (res.endsWith("\r\n") && !snippet.endsWith('\n'))
			res.length -= 2;
		else if (res.endsWith('\n') && !snippet.endsWith('\n'))
			res.length--;

		if (res.endsWith(";\n\n$0"))
			res = res[0 .. $ - "\n$0".length] ~ "$0";
		else if (res.endsWith(";\r\n\r\n$0"))
			res = res[0 .. $ - "\r\n$0".length] ~ "$0";

		return res;
	}

	/// Adds snippets which complete conditionally based on dub dependencies being present.
	/// This function affects the global configuration of all instances.
	/// Params:
	///   requiredDependencies = The dependencies which must be present in order for this snippet to show up.
	///   snippet = The snippet to suggest when the required dependencies are matched.
	void addDependencySnippet(string[] requiredDependencies, PlainSnippet snippet)
	{
		// maybe application global change isn't such a good idea? Current config system seems too inefficient for this.
		dependencySnippets.addSnippet(requiredDependencies, snippet);
	}

private:
	Future!(Snippet[])[] collectSnippets(scope const(char)[] file,
			scope const(char)[] code, int position)
	{
		const inst = instance;
		const info = determineSnippetInfo(file, code, position);
		auto futures = appender!(Future!(Snippet[])[]);
		foreach (provider; providers)
			futures.put(provider.provideSnippets(inst, file, code, position, info));
		return futures.data;
	}

	RollbackAllocator rba;
	LexerConfig config;
}

///
enum SnippetLevel
{
	/// Outside of functions or types, possibly inside templates
	global,
	/// Inside interfaces, classes, structs or unions
	type,
	/// Inside method body
	method,
	/// inside a variable value, argument call, default value or similar
	value,
	/// Other scope types (for example outside of braces but after a function definition or some other invalid syntax place)
	other
}

///
struct SnippetLoopScope
{
	/// true if an loop expression can be inserted at this point
	bool supported;
	/// true if we know we are iterating over a string (possibly needing unicode decoding) or false otherwise
	bool stringIterator;
	/// Explicit type to use when iterating or null if none is known
	string type;
	/// Best variable to iterate over or null if none was found
	string iterator;
	/// Number of keys to iterate over
	int numItems = 1;
}

///
struct SnippetInfo
{
	/// Levels this snippet location has gone through, latest one being the last
	SnippetLevel[] stack = [SnippetLevel.global];
	/// Information about snippets using loop context
	SnippetLoopScope loopScope;

	/// Current snippet scope level of the location
	SnippetLevel level() const @property
	{
		return stack.length ? stack[$ - 1] : SnippetLevel.other;
	}
}

///
interface SnippetProvider
{
	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info);

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet);
}

/// Snippet to insert
struct Snippet
{
	/// Internal ID for resolving this snippet
	string id, providerId;
	/// User-defined data for helping resolving this snippet
	JSONValue data;
	/// Label for this snippet
	string title;
	/// Shortcut to type for this snippet
	string shortcut;
	/// Markdown documentation for this snippet
	string documentation;
	/// Plain text to insert assuming global level indentation.
	string plain;
	/// Text with interactive snippet locations to insert assuming global indentation.
	string snippet;
	/// true if this snippet can be used as-is
	bool resolved;
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!SnippetsComponent;
	backend.register!DfmtComponent;
	SnippetsComponent snippets = backend.get!SnippetsComponent(workspace.directory);

	auto args = ["--indent_style", "tab"];

	auto res = snippets.formatSync("void main(${1:string[] args}) {\n\t$0\n}", args);
	shouldEqual(res, "void main(${1:string[] args})\n{\n\t$0\n}");

	res = snippets.formatSync("class ${1:MyClass} {\n\t$0\n}", args);
	shouldEqual(res, "class ${1:MyClass}\n{\n\t$0\n}");

	res = snippets.formatSync("enum ${1:MyEnum} = $2;\n$0", args);
	shouldEqual(res, "enum ${1:MyEnum} = $2;\n$0");

	res = snippets.formatSync("import ${1:std};\n$0", args);
	shouldEqual(res, "import ${1:std};\n$0");
}