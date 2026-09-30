// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause
//
// Behaviour harness for XCTestConfigurationLoader.
//
// The loader is the first unit in this framework that does something rather than
// being a value, and almost everything it decides is invisible from the API: it
// reads the process environment, a temporary directory and a plug-in directory,
// and answers with a configuration or nil. A harness is the only way to see any
// of it.
//
//   One scenario per process. The loader's third source is whatever
//   NSTemporaryDirectory() holds, and that is decided before main() runs. A
//   single process running every check would therefore share one temporary
//   directory across all of them, and "the newest configuration here is X" would
//   depend on which checks had already run. Worse, any check asserting that a
//   load found *nothing* would be reading files an earlier check had written.
//
//   The temporary directory cannot be pointed somewhere per scenario, and this is
//   worth being blunt about because it looks like it can: NSTemporaryDirectory()
//   answers confstr(_CS_DARWIN_USER_TEMP_DIR), which is the invoking user's own
//   directory and does not consult $TMPDIR. Setting TMPDIR changes where mktemp
//   puts things and nothing else. So source 3 is exercised against the real
//   directory, and the harness's obligations in exchange are narrow but real:
//
//     * Every file it writes there carries a per-run prefix, so two runs cannot
//       collide and a reader can tell what a leftover is.
//     * Every file it writes is registered and removed in an atexit handler, so
//       nothing survives a normal exit, and tools/check-loader.sh sweeps the
//       prefix again afterwards in case a scenario died on a signal.
//     * A check that needs the directory to hold *no* configuration asks first,
//       and skips with the offending names if something else put one there. This
//       is the case that makes the arrangement honest: the directory is shared
//       with every other process on the account, and a "finds nothing" assertion
//       made next to somebody else's file is not evidence of anything.
//
//   Source 4 is isolated by placement rather than by environment. The runner puts
//   a copy of this binary in a per-scenario directory, so NSBundle.mainBundle is
//   that directory and builtInPlugInsURL is a PlugIns directory under it that
//   this scenario alone can fill or leave empty.
//
//   What is worth a check. Not the setters -- -init and the two properties are
//   four lines and a typo in them is a compile error or a nil. What is worth a
//   check is the behaviour that compiles either way:
//
//     * Precedence between the four sources, established by putting two sources
//       in conflict and asserting which won rather than by testing one at a time
//       and hoping the order is implied.
//     * Falling through a source that failed. A present-but-unusable value is not
//       a reason to stop. This is the check most likely to be got wrong, because
//       writing `else if` looks exactly like writing two ifs until you point a
//       broken value at a directory that also holds a good one.
//     * Sources 1 and 2 returned untouched against 3 and 4 reset, which is
//       invisible unless a check reads the property the reset changes.
//     * The two scope spellings, which are not interchangeable: a scope file
//       names identifiers as an array, a defaults value names them as one
//       comma-separated string, and a harness using only the defaults form would
//       pass against an implementation that split a file's array on commas.
//     * The two defaults keys that differ by one word, `XCTest` and
//       `XCTestScope`, where reading the wrong one is silent: the scope is
//       ignored and the whole suite runs.
//
// Nothing here is exercised by the framework's own tests. This is a private
// framework with no runner of its own yet, which is the same reason the driver
// and the agent are still to come.
#import <XCTestCore/XCTestConfiguration.h>
#import <XCTestCore/XCTestConfigurationLoader.h>
#import <XCTestCore/XCTTestSelection.h>

#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/time.h>
#import <unistd.h>

#import <Foundation/Foundation.h>
// Not pulled in by the reduced <Foundation/Foundation.h>, and every fixture here
// is built by keyed coding.
#import <Foundation/NSKeyedArchiver.h>

static NSUInteger checksRun = 0;
static NSUInteger checksFailed = 0;

static void Check(BOOL condition, NSString *name)
{
    checksRun++;
    if (condition) {
        fprintf(stdout, "  %-64s PASS\n", name.UTF8String);
    } else {
        checksFailed++;
        fprintf(stdout, "  %-64s FAIL\n", name.UTF8String);
    }
}

/// A check that cannot be made honestly in this environment, reported as skipped
/// rather than as a pass.
///
/// The alternative -- asserting something true that was not tested -- is how a
/// harness stops being evidence, and this is a real case rather than a
/// hypothetical one: the loader reads the *standard* defaults domain, and a
/// developer with a real scope configured would silently invalidate a check that
/// claimed to have proved otherwise.
static void Skip(NSString *name, NSString *why)
{
    checksRun++;
    fprintf(stdout, "  %-64s SKIP (%s)\n", name.UTF8String, why.UTF8String);
}

#pragma mark - Fixtures

/// Writes bytes to `path` and answers whether it worked.
///
/// stdio rather than -[NSData writeToFile:atomically:], which this SDK does not
/// declare. The loader needs the same two selectors and declares them in
/// XCTestCoreFoundationCompat.h, which is a private header of the framework; a
/// harness built against the installed framework has no business importing it, so
/// it does the one thing it needs here instead.
static BOOL WriteBytes(NSString *path, NSData *data)
{
    FILE *file = fopen(path.UTF8String, "wb");
    if (!file) {
        fprintf(stdout, "  !! could not open %s for writing: %s\n", path.UTF8String, strerror(errno));
        return NO;
    }
    size_t written = fwrite(data.bytes, 1, data.length, file);
    int failed = fclose(file);
    if (written != data.length || failed) {
        fprintf(stdout, "  !! could not write %s\n", path.UTF8String);
        return NO;
    }
    return YES;
}

/// Writes a configuration to `path` and answers whether it worked. A NO fails
/// the check that needed it, so a fixture problem is never mistaken for a loader
/// problem.
static BOOL WriteConfigurationArchive(XCTestConfiguration *configuration, NSString *path)
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:configuration
                                        requiringSecureCoding:YES
                                                        error:&error];
    if (!data) {
        fprintf(stdout, "  !! could not archive a configuration: %s\n",
                error.localizedDescription.UTF8String);
        return NO;
    }
    return WriteBytes(path, data);
}

/// The base64 spelling of a configuration, which is how source 1 receives one.
///
/// Written out rather than taken from Foundation, which declares
/// -base64EncodedStringWithOptions: on some SDKs and not this one. The encoding
/// is not taken on trust: every check that uses it goes through the loader's own
/// decoder, so a wrong alphabet or a wrong final quantum shows up as a
/// configuration that does not load.
static NSString *Base64Encode(NSData *data)
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    char *out = malloc(((length + 2) / 3) * 4 + 1);
    if (!out) {
        return nil;
    }
    NSUInteger written = 0;
    for (NSUInteger i = 0; i < length; i += 3) {
        unsigned int quantum = (unsigned)bytes[i] << 16;
        if (i + 1 < length) {
            quantum |= (unsigned)bytes[i + 1] << 8;
        }
        if (i + 2 < length) {
            quantum |= (unsigned)bytes[i + 2];
        }
        out[written++] = alphabet[(quantum >> 18) & 0x3F];
        out[written++] = alphabet[(quantum >> 12) & 0x3F];
        out[written++] = (i + 1 < length) ? alphabet[(quantum >> 6) & 0x3F] : '=';
        out[written++] = (i + 2 < length) ? alphabet[quantum & 0x3F] : '=';
    }
    out[written] = '\0';
    NSString *encoded = [[NSString alloc] initWithUTF8String:out];
    free(out);
    return encoded;
}

/// The base64 spelling of a configuration.
static NSString *EncodedConfiguration(XCTestConfiguration *configuration)
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:configuration
                                        requiringSecureCoding:YES
                                                        error:&error];
    return data ? Base64Encode(data) : nil;
}

/// Two configurations that differ in a way a check can see after a load.
///
/// -targetApplicationPath is the tag because it is a plain copied string that
/// survives an archive round trip. A configuration a loader hands back would
/// otherwise be indistinguishable from one it synthesized, and every precedence
/// check has to tell those apart.
static XCTestConfiguration *ConfigurationTagged(NSString *tag)
{
    XCTestConfiguration *configuration = [[XCTestConfiguration alloc] init];
    configuration.targetApplicationPath = tag;
    return configuration;
}

static NSString *TagOf(XCTestConfiguration *configuration)
{
    return configuration.targetApplicationPath;
}

/// A loader with nothing named, which is how a check asks "and what did discovery
/// find?" without also naming a source.
static XCTestConfigurationLoader *LoaderNamingNothing(void)
{
    return [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:nil
                                                                encodedEnvironmentValue:nil];
}

static XCTestConfigurationLoader *LoaderNamingURL(NSString *path)
{
    return [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:
                                                        [NSURL fileURLWithPath:path]
                                                             encodedEnvironmentValue:nil];
}

static XCTestConfigurationLoader *LoaderNamingEncoded(XCTestConfiguration *configuration)
{
    return [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:nil
                                                             encodedEnvironmentValue:
                                                                 EncodedConfiguration(configuration)];
}

static XCTestConfigurationLoader *LoaderNamingBoth(NSString *path, XCTestConfiguration *configuration)
{
    return [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:
                                                        [NSURL fileURLWithPath:path]
                                                             encodedEnvironmentValue:
                                                                 EncodedConfiguration(configuration)];
}

/// Pins a file's modification date.
///
/// Absolute rather than a relative offset, and not because the loader needs a
/// particular date: it needs them to *differ*. Two files written in the same
/// second are a tie, the loader resolves a tie by enumeration order, and
/// enumeration order is not something a check should depend on.
static void SetModificationDate(NSString *path, long offsetSeconds)
{
    struct timeval stamp;
    stamp.tv_sec = (time_t)(1600000000 + offsetSeconds);
    stamp.tv_usec = 0;
    if (utimes(path.UTF8String, &stamp) != 0) {
        fprintf(stdout, "  !! could not date %s: %s\n", path.UTF8String, strerror(errno));
    }
}

#pragma mark - The shared temporary directory

/// The per-run prefix every file this harness puts in the temporary directory
/// carries. Set from argv by the runner, and unique to the run rather than to the
/// process, so that two runs of check-loader.sh cannot read each other's files.
static NSString *runPrefix = @"xctcore-loader";

/// The paths written into the temporary directory, so an atexit handler can take
/// them back out. A static array rather than a Foundation collection because this
/// runs after the autorelease pool is gone, and a collection would be of no use by
/// then anyway.
static char *createdTemporaryPaths[64];
static size_t createdTemporaryPathCount = 0;

static void RemoveCreatedTemporaryPaths(void)
{
    for (size_t i = 0; i < createdTemporaryPathCount; i++) {
        unlink(createdTemporaryPaths[i]);
    }
    createdTemporaryPathCount = 0;
}

/// A path in the temporary directory carrying the run's prefix.
///
/// This is where source 3 looks, so it is the one directory a check cannot have to
/// itself. The prefix is not decoration: it is what makes cleanup a prefix sweep
/// rather than a guess about which files are ours.
static NSString *TemporaryPath(NSString *name)
{
    NSString *filename = [NSString stringWithFormat:@"%@-%@", runPrefix, name];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
}

/// Registers a temporary-directory path for removal and answers whether there was
/// room to register it. A full table means the harness has written 64 files into
/// the user's temporary directory, which is already a bug worth failing on rather
/// than a condition to keep going through.
static BOOL RememberTemporaryPath(NSString *path)
{
    if (createdTemporaryPathCount >= sizeof(createdTemporaryPaths) / sizeof(*createdTemporaryPaths)) {
        fprintf(stdout, "  !! too many temporary fixtures to clean up safely\n");
        return NO;
    }
    createdTemporaryPaths[createdTemporaryPathCount++] = strdup(path.UTF8String);
    return createdTemporaryPaths[createdTemporaryPathCount - 1] != NULL;
}

/// Writes a file into the temporary directory and remembers to remove it.
static BOOL WriteTemporaryBytes(NSString *name, NSData *data)
{
    NSString *path = TemporaryPath(name);
    if (!WriteBytes(path, data)) {
        return NO;
    }
    if (!RememberTemporaryPath(path)) {
        unlink(path.UTF8String);
        return NO;
    }
    return YES;
}

/// Writes a configuration into the temporary directory and remembers to remove it.
static BOOL WriteTemporaryConfiguration(NSString *name, XCTestConfiguration *configuration)
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:configuration
                                        requiringSecureCoding:YES
                                                        error:&error];
    if (!data) {
        fprintf(stdout, "  !! could not archive a configuration: %s\n",
                error.localizedDescription.UTF8String);
        return NO;
    }
    return WriteTemporaryBytes(name, data);
}

/// The names of the configurations in the temporary directory that this harness did
/// not write, or nil if there are none.
///
/// The one thing a "discovery found nothing" check needs from the world. The
/// temporary directory belongs to the account, not to this run, so a file there
/// that the loader can read is somebody else's business -- and asserting nil
/// beside it would be asserting that their file is not there, which is a
/// statement about their run and not about this loader.
static NSString *ForeignConfigurationsInTemporaryDirectory(void)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *mine = runPrefix;
    NSArray<NSString *> *contents =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL];
    for (NSString *name in contents) {
        if (![name.pathExtension isEqualToString:@"xctestconfiguration"]) {
            continue;
        }
        if ([name hasPrefix:mine]) {
            continue;
        }
        [names addObject:name];
    }
    NSMutableString *list = [NSMutableString string];
    for (NSString *name in names) {
        if (list.length > 0) {
            [list appendString:@", "];
        }
        [list appendString:name];
    }
    return list.length == 0 ? nil : list;
}

/// Puts values in the registration domain and answers whether they are what
/// -stringForKey: will actually read back.
///
/// The registration domain is the only way to name a scope from a harness. The
/// reduced SDK does not declare -initWithSuiteName:, and writing to the standard
/// domain would edit the developer's own preferences -- and the scope keys are
/// real keys a developer may legitimately have set. Registration is
/// process-local and writes nothing to disk, so there is nothing to clean up.
///
/// The shadowing check is the load-bearing part. Registration sits *below* the
/// persistent domains, so a machine that really has `XCTest` set would silently
/// shadow the value registered here and the checks would pass or fail for a
/// reason that has nothing to do with the loader. Rather than report that as a
/// pass, this answers NO and the scenario says so.
static BOOL RegisterScope(NSString *name, NSString *scope, NSNumber *invert, NSString *scopeFile)
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    if (scope) {
        values[@"XCTest"] = scope;
    }
    if (invert) {
        values[@"XCTestInvertScope"] = invert;
    }
    if (scopeFile) {
        values[@"XCTestScopeFile"] = scopeFile;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:values];
    for (NSString *key in values) {
        if (![values[key] isEqual:[defaults objectForKey:key]]) {
            fprintf(stdout, "  ~~ %s is shadowed by this account's defaults for key %s\n",
                    name.UTF8String, key.UTF8String);
            return NO;
        }
    }
    return YES;
}

/// Runs `body` with stderr redirected to `path`, and answers what was written.
///
/// Used for the deprecated-scope message, which the reference writes to stderr
/// rather than to the log. Redirecting rather than reading the terminal is what
/// makes it checkable: a message that appears in a captured log nobody diffs is
/// indistinguishable from a message that never appears.
static NSString *CaptureStderr(NSString *path, void (^body)(void))
{
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    FILE *redirected = freopen(path.UTF8String, "w", stderr);
    body();
    fflush(stderr);
    if (redirected) {
        dup2(saved, STDERR_FILENO);
    }
    close(saved);
    FILE *file = fopen(path.UTF8String, "rb");
    if (!file) {
        return @"";
    }
    NSMutableData *data = [NSMutableData data];
    char buffer[512];
    size_t read;
    while ((read = fread(buffer, 1, sizeof(buffer), file)) > 0) {
        [data appendBytes:buffer length:read];
    }
    fclose(file);
    NSString *captured = [[NSString alloc] initWithBytes:data.bytes length:data.length
                                                encoding:NSUTF8StringEncoding];
    return captured ?: @"";
}

/// Whether this account's own defaults already name a scope, which would shadow
/// anything a harness registers and make every settings check in the process
/// meaningless. Asked before anything is registered, so `objectForKey:` sees only
/// the persistent domains.
static BOOL ScopeKeysShadowed(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[ @"XCTest", @"XCTestScopeFile", @"XCTestInvertScope" ]) {
        if ([defaults objectForKey:key]) {
            fprintf(stdout, "  ~~ %s is set in this account's defaults\n", key.UTF8String);
            return YES;
        }
    }
    return NO;
}

#pragma mark - Source 1: the encoded environment value

static void ScenarioEncodedValue(NSString *fixtures)
{
    XCTestConfiguration *tagged = ConfigurationTagged(@"encoded");
    XCTestConfigurationLoader *loader = LoaderNamingEncoded(tagged);
    XCTestConfiguration *configuration = [loader loadTestConfiguration];
    Check(configuration != nil, @"a valid base64 blob loads a configuration");
    Check([TagOf(configuration) isEqualToString:@"encoded"], @"and it is the one that was encoded");

    // The environment method is source 2's method and does not read the encoded
    // value at all, so this is not the same question asked twice. Which sources a
    // method covers is invisible from its name.
    Check([loader loadTestConfigurationFromEnvironmentWithDidSpecify:NULL] == nil,
          @"the environment method does not read the encoded value");

    // A blob that is not base64 has to fall through rather than raise: the loader's
    // job is to answer "no configuration" for anything it cannot use, and a
    // process that raised here would take the run down over an environment
    // variable somebody set by hand. The answer is nil only when nothing else is
    // there to be found, so the directory has to be asked about first.
    NSString *foreign = ForeignConfigurationsInTemporaryDirectory();
    if (foreign) {
        Skip(@"a value that is not base64 loads nothing",
             [NSString stringWithFormat:@"the temporary directory holds %@", foreign]);
        Skip(@"valid base64 that is not an archive loads nothing",
             [NSString stringWithFormat:@"the temporary directory holds %@", foreign]);
    } else {
        XCTestConfigurationLoader *notBase64 =
            [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:nil
                                                                 encodedEnvironmentValue:@"!!! not base64 !!!"];
        Check([notBase64 loadTestConfiguration] == nil, @"a value that is not base64 loads nothing");

        // Valid base64 that is not an archive. The unarchiver's own error is
        // discarded by design, so this is a nil and not a raise.
        NSString *validBase64NotArchive =
            Base64Encode([@"not an archive at all" dataUsingEncoding:NSUTF8StringEncoding]);
        XCTestConfigurationLoader *notAnArchive =
            [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:nil
                                                                 encodedEnvironmentValue:validBase64NotArchive];
        Check([notAnArchive loadTestConfiguration] == nil,
              @"valid base64 that is not an archive loads nothing");
    }

    // The properties round-trip, and a nil stays nil rather than becoming an empty
    // string. "The environment named no source" and "the environment named an
    // empty source" are different questions and only one of them is legal.
    NSString *empty = @"";
    XCTestConfigurationLoader *roundTrip =
        [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:nil
                                                             encodedEnvironmentValue:empty];
    Check([roundTrip.testConfigurationEncodedValueFromEnvironment isEqualToString:empty],
          @"an empty encoded value is stored as an empty string, not nil");
    Check(roundTrip.testConfigurationURLFromEnvironment == nil, @"a nil URL stays nil");
    Check([LoaderNamingNothing() testConfigurationEncodedValueFromEnvironment] == nil,
          @"a nil encoded value stays nil");

    (void)fixtures;
}

#pragma mark - Source 2: the path

static void ScenarioPathSource(NSString *fixtures)
{
    NSString *path = [fixtures stringByAppendingPathComponent:@"from-path.xctestconfiguration"];
    if (!WriteConfigurationArchive(ConfigurationTagged(@"path"), path)) {
        Check(NO, @"fixture: a configuration could be archived");
        return;
    }
    XCTestConfiguration *configuration = [LoaderNamingURL(path) loadTestConfiguration];
    Check(configuration != nil, @"an existing file loads a configuration");
    Check([TagOf(configuration) isEqualToString:@"path"], @"and it is the one in that file");

    // didSpecify is about the environment naming a source, not about that source
    // working. A driver has to be able to tell "the one you gave me did not load"
    // from "you gave me nothing", and only the first is worth failing over, so
    // these two have to disagree.
    NSString *absent = [fixtures stringByAppendingPathComponent:@"absent.xctestconfiguration"];
    BOOL didSpecify = NO;
    Check([LoaderNamingURL(absent) loadTestConfigurationFromEnvironmentWithDidSpecify:&didSpecify] == nil,
          @"a path that does not exist loads nothing");
    Check(didSpecify, @"but didSpecify is still YES: the environment named it");

    didSpecify = YES;
    Check([LoaderNamingNothing() loadTestConfigurationFromEnvironmentWithDidSpecify:&didSpecify] == nil,
          @"no named source loads nothing");
    Check(!didSpecify, @"and didSpecify is NO");

    // A NULL out-parameter is permitted; asking a caller that does not care to
    // invent a BOOL it will ignore is noise.
    Check([LoaderNamingNothing() loadTestConfigurationFromEnvironmentWithDidSpecify:NULL] == nil,
          @"a NULL didSpecify is permitted");

    // The environment method must not fall back. Asking it about a path that does
    // not exist is the check: a fallback would have to reach discovery, and the
    // answer would then depend on what the account's temporary directory holds
    // rather than on anything about the two sources.
    Check([LoaderNamingURL(absent) loadTestConfigurationFromEnvironmentWithDidSpecify:NULL] == nil,
          @"the environment method never falls back to discovery");

    // An empty path is not the working directory and is not a URL that cannot be
    // read: Foundation answers nil for it, so nothing is stored and the loader is
    // back to having no source named. Asserted because the alternative is easy to
    // believe -- a URL for "" looks like it should name the current directory --
    // and because the consequence is a silent fall-through to discovery.
    XCTestConfigurationLoader *emptyPath =
        [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:
                                                            [NSURL fileURLWithPath:@""]
                                                             encodedEnvironmentValue:nil];
    Check([NSURL fileURLWithPath:@""].path == nil,
          @"Foundation answers no path for an empty one, so there is no URL to store");
    Check(emptyPath.testConfigurationURLFromEnvironment == nil,
          @"and an empty path stores no URL at all");
}

static void ScenarioRelativePath(NSString *fixtures)
{
    NSString *name = @"relative.xctestconfiguration";
    if (!WriteConfigurationArchive(ConfigurationTagged(@"relative"),
                                   [fixtures stringByAppendingPathComponent:name])) {
        Check(NO, @"fixture: a configuration could be archived");
        return;
    }

    // A relative path has to be resolved against the working directory, or the run
    // looks in the wrong place and finds nothing -- which is indistinguishable,
    // from the outside, from a configuration that was never written. That is why
    // this is checked by making the file findable and the working directory
    // somewhere else first.
    //
    // The resolution is Foundation's, not the loader's, and the stored URL says so:
    // +[NSURL fileURLWithPath:] answers an absolute URL. Asserting that here is
    // worth more than it looks, because it is what makes the loader's own
    // resolution a no-op for a path that came from the environment -- the branch
    // only runs for a URL built some other way.
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *original = [fileManager currentDirectoryPath];
    if (![fileManager changeCurrentDirectoryPath:fixtures]) {
        Check(NO, @"fixture: the working directory could be changed");
        return;
    }
    // Read back from NSFileManager rather than reusing `fixtures`: Foundation
    // resolves what it is given, and on this platform the resolved form of a
    // directory under /var is /private/var. Comparing against the argument would
    // be comparing against a spelling that is right in the source and wrong here.
    NSString *expected = [[fileManager currentDirectoryPath] stringByAppendingPathComponent:name];
    XCTestConfigurationLoader *loader = LoaderNamingURL(name);
    Check([loader.testConfigurationURLFromEnvironment.path isEqualToString:expected],
          @"a relative path becomes absolute against the working directory");
    Check([TagOf([loader loadTestConfigurationFromEnvironmentWithDidSpecify:NULL])
              isEqualToString:@"relative"],
          @"and loads the file sitting there");
    [fileManager changeCurrentDirectoryPath:original];

    // The same relative name, resolved from somewhere else, means somewhere else
    // entirely and must not find the file.
    Check([LoaderNamingURL(name) loadTestConfigurationFromEnvironmentWithDidSpecify:NULL] == nil,
          @"a relative path resolved from elsewhere finds nothing");
}

#pragma mark - Precedence

static void ScenarioPrecedence(NSString *fixtures)
{
    NSString *path = [fixtures stringByAppendingPathComponent:@"precedence.xctestconfiguration"];
    if (!WriteConfigurationArchive(ConfigurationTagged(@"path"), path)) {
        Check(NO, @"fixture: a configuration could be archived");
        return;
    }

    // The encoded value is decoded before the path is opened. Both are present
    // and both work, so only the order can decide this.
    XCTestConfigurationLoader *both = LoaderNamingBoth(path, ConfigurationTagged(@"encoded"));
    Check([TagOf([both loadTestConfiguration]) isEqualToString:@"encoded"],
          @"a present encoded value wins over a present path");

    // A present-but-broken encoded value must fall through to the path rather than
    // ending the chain. `else if` gets this wrong and still returns a configuration
    // for every input that is wholly valid, so the check has to break exactly one
    // of the two.
    XCTestConfigurationLoader *brokenThenGood =
        [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:
                                                            [NSURL fileURLWithPath:path]
                                                             encodedEnvironmentValue:@"!!! not base64 !!!"];
    Check([TagOf([brokenThenGood loadTestConfiguration]) isEqualToString:@"path"],
          @"a broken encoded value falls through to a good path");

    // The mirror image: a path that is not there is never reached when the encoded
    // value worked.
    XCTestConfigurationLoader *goodThenBroken =
        [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:
                                            [NSURL fileURLWithPath:
                                                [fixtures stringByAppendingPathComponent:@"absent"]]
                                                             encodedEnvironmentValue:
                                                                 EncodedConfiguration(
                                                                     ConfigurationTagged(@"encoded"))];
    Check([TagOf([goodThenBroken loadTestConfiguration]) isEqualToString:@"encoded"],
          @"a broken path is never reached when the encoded value worked");

    // Two broken sources answer nil, not a guess. The check needs the temporary
    // directory to hold nothing, because a fallback would find whatever is there
    // and return that instead of the nil being asserted.
    NSString *foreign = ForeignConfigurationsInTemporaryDirectory();
    if (foreign) {
        Skip(@"two broken sources answer nil rather than a guess",
             [NSString stringWithFormat:@"the temporary directory holds %@", foreign]);
        return;
    }
    XCTestConfigurationLoader *brokenThenNothing =
        [[XCTestConfigurationLoader alloc] initWithTestConfigurationURLFromEnvironment:
                                            [NSURL fileURLWithPath:
                                                [fixtures stringByAppendingPathComponent:@"absent"]]
                                                             encodedEnvironmentValue:@"!!! not base64 !!!"];
    Check([brokenThenNothing loadTestConfiguration] == nil, @"two broken sources answer nil rather than a guess");
}

#pragma mark - Source 3: the temporary directory

static void ScenarioDiscoveryOrder(NSString *fixtures)
{
    // The directory is the account's own and cannot be pointed elsewhere, so what
    // is asserted is that these files are in it and are the ones that get read.
    // Dates are absolute and far apart, because the loader resolves a tie by
    // enumeration order and enumeration order is not something a check may depend
    // on.
    if (!WriteTemporaryConfiguration(@"older.xctestconfiguration", ConfigurationTagged(@"older")) ||
        !WriteTemporaryConfiguration(@"newer.xctestconfiguration", ConfigurationTagged(@"newer")) ||
        !WriteTemporaryBytes(@"newest.txt", [@"decoy" dataUsingEncoding:NSUTF8StringEncoding])) {
        Check(NO, @"fixture: two configurations and a decoy could be written");
        return;
    }
    SetModificationDate(TemporaryPath(@"older.xctestconfiguration"), 0);
    SetModificationDate(TemporaryPath(@"newer.xctestconfiguration"), 60);
    SetModificationDate(TemporaryPath(@"newest.txt"), 120);

    XCTestConfiguration *configuration = [LoaderNamingNothing() loadTestConfiguration];
    Check(configuration != nil, @"a configuration in the temporary directory is found");
    // The decoy is newer than both configurations and is still not chosen, which
    // is what separates filtering by extension from taking the newest file of any
    // kind.
    Check([TagOf(configuration) isEqualToString:@"newer"], @"the newest configuration wins, not the newest file");

    // Directories are not searched, and a configuration in a subdirectory of the
    // temporary directory belongs to some other run.
    NSString *nested = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [runPrefix stringByAppendingPathComponent:@"nested"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:nested
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    NSString *nestedFile = [nested stringByAppendingPathComponent:@"nested.xctestconfiguration"];
    if (WriteConfigurationArchive(ConfigurationTagged(@"nested"), nestedFile)) {
        SetModificationDate(nestedFile, 900);
        Check([TagOf([LoaderNamingNothing() loadTestConfiguration]) isEqualToString:@"newer"],
              @"a configuration in a subdirectory is not found");
    }
    // Taken back out explicitly rather than left to the atexit sweep, which knows
    // about files and not about the directory that held one.
    if (unlink(nestedFile.UTF8String) != 0 || rmdir(nested.UTF8String) != 0) {
        fprintf(stdout, "  !! could not remove %s: %s\n", nested.UTF8String, strerror(errno));
    }
    (void)fixtures;
}

static void ScenarioDiscoveryNone(NSString *fixtures)
{
    // "Found nothing" is only a statement about the loader if the directory really
    // holds nothing it can read. A file this harness wrote is removed first, so
    // the only thing that can fail this check is a file from another process.
    RemoveCreatedTemporaryPaths();

    NSString *foreign = ForeignConfigurationsInTemporaryDirectory();
    if (foreign) {
        Skip(@"a temporary directory with no configuration finds nothing",
             [NSString stringWithFormat:@"the temporary directory holds %@", foreign]);
        (void)fixtures;
        return;
    }

    // A file that is not a configuration, and nothing else. This is what "found
    // nothing" looks like in the wild: a directory full of other people's files.
    if (!WriteTemporaryBytes(@"notes.txt", [@"decoy" dataUsingEncoding:NSUTF8StringEncoding])) {
        Check(NO, @"fixture: a decoy could be written");
        return;
    }
    SetModificationDate(TemporaryPath(@"notes.txt"), 120);
    Check([LoaderNamingNothing() loadTestConfiguration] == nil,
          @"a temporary directory with no configuration finds nothing");
    (void)fixtures;
}

#pragma mark - The reporting reset, from both sides

static void ScenarioReporting(NSString *fixtures)
{
    // One configuration, written twice: once where an explicit source can name it
    // and once where discovery will. Same bytes, different source, so the only
    // thing that can explain a difference in -sessionIdentifier is the source.
    XCTestConfiguration *original = [[XCTestConfiguration alloc] init];
    original.targetApplicationPath = @"reporting";
    NSString *named = [fixtures stringByAppendingPathComponent:@"reporting-named.xctestconfiguration"];
    if (!WriteConfigurationArchive(original, named) ||
        !WriteTemporaryConfiguration(@"reporting-found.xctestconfiguration", original)) {
        Check(NO, @"fixture: the same configuration could be archived twice");
        return;
    }
    SetModificationDate(TemporaryPath(@"reporting-found.xctestconfiguration"), 0);

    XCTestConfiguration *untouched = [LoaderNamingURL(named) loadTestConfiguration];
    Check(untouched.sessionIdentifier != nil,
          @"a configuration the environment named keeps its session identifier");
    Check(untouched.emitOSLogs == NO, @"and keeps emitOSLogs as it was written");
    Check(untouched.testIdentifiersToRun == nil, @"and is given no selection of its own");

    XCTestConfiguration *discovered = [LoaderNamingNothing() loadTestConfiguration];
    Check([TagOf(discovered) isEqualToString:@"reporting"], @"discovery found the same configuration");
    Check(discovered.sessionIdentifier == nil, @"found by discovery, it has its session identifier cleared");
    // The other half of the clear, and the half that survives into the run: whoever
    // finds a stale configuration wants the log it produces.
    Check(discovered.emitOSLogs, @"and a found configuration turns OS logging on");
}

#pragma mark - -init

static void ScenarioInitFromEnvironment(NSString *fixtures)
{
    NSString *path = [fixtures stringByAppendingPathComponent:@"init.xctestconfiguration"];
    NSString *encoded = EncodedConfiguration(ConfigurationTagged(@"encoded"));
    if (!encoded || !WriteConfigurationArchive(ConfigurationTagged(@"init"), path)) {
        Check(NO, @"fixture: a configuration could be archived and encoded");
        return;
    }

    // -init is the only thing that reads the environment, so this is where the two
    // keys are spelled out. A harness that only used the two-argument initializer
    // would never notice one of them being misspelled.
    setenv("XCTestConfigurationFilePath", path.UTF8String, 1);
    setenv("XCTestConfigurationEncodedValueEnvironmentKey", encoded.UTF8String, 1);
    XCTestConfigurationLoader *both = [[XCTestConfigurationLoader alloc] init];
    Check([both.testConfigurationURLFromEnvironment.path isEqualToString:path],
          @"-init turns XCTestConfigurationFilePath into a file URL");
    Check([both.testConfigurationEncodedValueFromEnvironment isEqualToString:encoded],
          @"-init stores the encoded value");
    Check([TagOf([both loadTestConfiguration]) isEqualToString:@"encoded"],
          @"and the encoded value is preferred, as source 1 is source 1");

    // A path only: the second source, and the one a driver hands over directly.
    unsetenv("XCTestConfigurationEncodedValueEnvironmentKey");
    XCTestConfigurationLoader *pathOnly = [[XCTestConfigurationLoader alloc] init];
    Check([TagOf([pathOnly loadTestConfiguration]) isEqualToString:@"init"],
          @"XCTestConfigurationFilePath alone loads its file");

    // An empty path stores nothing, because Foundation answers nil for it rather
    // than a URL naming the working directory. So this variable set to the empty
    // string is the same loader as this variable unset, and both fall through to
    // discovery.
    setenv("XCTestConfigurationFilePath", "", 1);
    XCTestConfigurationLoader *emptyPath = [[XCTestConfigurationLoader alloc] init];
    Check(emptyPath.testConfigurationURLFromEnvironment == nil,
          @"an empty path stores no URL, exactly as an unset one does");

    unsetenv("XCTestConfigurationFilePath");
    XCTestConfigurationLoader *bare = [[XCTestConfigurationLoader alloc] init];
    Check(bare.testConfigurationURLFromEnvironment == nil &&
              bare.testConfigurationEncodedValueFromEnvironment == nil,
          @"with nothing in the environment, -init stores nothing");

    // The environment method answers nothing because the environment named no
    // path, which is a claim about one key and nothing else. Note that it does not
    // consult the encoded value: it is source 2's method, and asking it about a
    // blob is a question it does not answer.
    Check([bare loadTestConfigurationFromEnvironmentWithDidSpecify:NULL] == nil,
          @"and the environment method loads nothing from the environment");
    NSString *foreign = ForeignConfigurationsInTemporaryDirectory();
    if (foreign) {
        Skip(@"and a loader with nothing named finds nothing",
             [NSString stringWithFormat:@"the temporary directory holds %@", foreign]);
    } else {
        Check([bare loadTestConfiguration] == nil, @"and a loader with nothing named finds nothing");
    }
}

#pragma mark - +testIdentifierSetForIdentifiers:outError:

/// The set the builder makes from a list, so that the loader's checks can be about
/// the loader. How many identifiers one spelling of a name is worth is the
/// builder's business and is settled in builder-test.m; what the loader owes is
/// that it hands the list over whole and takes the builder's answer unchanged.
static NSUInteger BuilderCountForIdentifiers(NSArray<NSString *> *identifiers)
{
    XCTTestIdentifierSetBuilder *builder = [[XCTTestIdentifierSetBuilder alloc] init];
    for (NSString *identifier in identifiers) {
        [builder addTestIdentifiersForStringRepresentation:identifier
                                    includingSwiftCounterpart:NO];
    }
    return builder.testIdentifierSet.count;
}

static void ScenarioIdentifierSet(void)
{
    NSError *error = nil;
    NSArray *valid = @[ @"MyTests/testFoo", @"MyTests/testBar" ];
    XCTTestIdentifierSet *set = [XCTestConfigurationLoader testIdentifierSetForIdentifiers:valid
                                                                                 outError:&error];
    Check(set != nil, @"a list of valid identifiers builds a set");
    Check(error == nil, @"and leaves no error");
    Check(set.count == BuilderCountForIdentifiers(valid),
          @"and is exactly what the builder makes of the same list");

    // A parameterized Swift Testing name is one test named two ways, and
    // includingSwiftCounterpart:NO is what keeps a selection that named it from
    // running two. Compared against the builder rather than a literal count, so
    // that this stays a statement about the loader.
    NSArray *swiftNamed = @[ @"MyTests/testFoo()" ];
    XCTTestIdentifierSet *fromSwiftName =
        [XCTestConfigurationLoader testIdentifierSetForIdentifiers:swiftNamed outError:NULL];
    Check(fromSwiftName != nil, @"a parameterized Swift Testing name parses");
    Check(fromSwiftName.count == BuilderCountForIdentifiers(swiftNamed),
          @"and adds only the primary spelling");

    // An empty list is not an error and produces an empty set, which is also what
    // a scope file with no XCTestScope key means.
    XCTTestIdentifierSet *empty = [XCTestConfigurationLoader testIdentifierSetForIdentifiers:@[]
                                                                                outError:NULL];
    Check(empty != nil && empty.count == 0, @"an empty list builds an empty set");

    // The empty string is the one entry the builder refuses: every non-empty string
    // has a Swift Testing reading, so there is no junk this can catch. That is
    // worth stating, because it is why a scope typo is reported as an unparseable
    // identifier rather than as a scope error.
    error = nil;
    Check([XCTestConfigurationLoader testIdentifierSetForIdentifiers:@[ @"MyTests/testFoo", @"" ]
                                                           outError:&error] == nil,
          @"a list containing an empty entry builds nothing");
    Check([error.domain isEqualToString:@"com.apple.XCTestErrorDomain"], @"in XCTest's error domain");
    Check(error.code == -500, @"with the reference's code");
    Check([error.localizedDescription isEqualToString:@"Invalid test identifier: "],
          @"naming the entry that did not parse");

    // A NULL error pointer is permitted, and is still a failure.
    Check([XCTestConfigurationLoader testIdentifierSetForIdentifiers:@[ @"" ] outError:NULL] == nil,
          @"a NULL outError is permitted");
}

#pragma mark - +applySettingsFromUserDefaultsIfApplicable:

static void ScenarioScopeFromDefaults(NSString *fixtures)
{
    if (ScopeKeysShadowed()) {
        Skip(@"a comma-separated scope in XCTest is accepted", @"this account already has a scope");
        return;
    }
    XCTestConfiguration *configuration = [[XCTestConfiguration alloc] init];

    // The comma-separated form, read from the key `XCTest`. The key is the point
    // as much as the value: it differs by one word from the plist key inside a
    // scope file, and reading the wrong one is silent.
    if (RegisterScope(@"comma", @"MyTests/testFoo,MyTests/testBar", nil, nil)) {
        NSError *error = nil;
        Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                                             commandLineArguments:@[]
                                                               testConfiguration:configuration
                                                                        outError:&error],
              @"a comma-separated scope in XCTest is accepted");
        Check(error == nil, @"with no error");
        Check(configuration.testIdentifiersToRun.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo", @"MyTests/testBar" ]),
              @"and builds the set the builder makes of those components");
    }

    // Inversion moves the same set from the run list to the skip list, and only
    // one of the two at a time: an inverted scope must not also claim the run list.
    if (RegisterScope(@"invert", @"MyTests/testFoo", @YES, nil)) {
        XCTestConfiguration *inverted = [[XCTestConfiguration alloc] init];
        Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                                             commandLineArguments:@[]
                                                               testConfiguration:inverted
                                                                        outError:NULL],
              @"an inverted scope is accepted");
        Check(inverted.testIdentifiersToSkip.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo" ]),
              @"and lands in the skip list");
        Check(inverted.testIdentifiersToRun == nil, @"without also claiming the run list");
    }

    // All is the default and changes nothing.
    if (RegisterScope(@"all", @"All", nil, nil)) {
        XCTestConfiguration *all = [[XCTestConfiguration alloc] init];
        Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                                             commandLineArguments:@[]
                                                               testConfiguration:all
                                                                        outError:NULL],
              @"All is accepted");
        Check(all.testIdentifiersToRun == nil && all.testIdentifiersToSkip == nil,
              @"and leaves the selection alone");
    }

    // None and Self are deprecated rather than rejected, because a defaults domain
    // written years ago should still run. They behave as All -- which is what
    // distinguishes them from a scope that named nothing and had to be rejected.
    for (NSString *legacy in @[ @"None", @"Self" ]) {
        if (!RegisterScope([NSString stringWithFormat:@"legacy-%@", legacy], legacy, nil, nil)) {
            continue;
        }
        XCTestConfiguration *configuration = [[XCTestConfiguration alloc] init];
        NSString *captured = CaptureStderr([fixtures stringByAppendingPathComponent:@"stderr.txt"], ^{
            Check([XCTestConfigurationLoader
                      applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                          commandLineArguments:@[]
                                            testConfiguration:configuration
                                                     outError:NULL],
                  ([NSString stringWithFormat:@"the deprecated scope %@ is accepted", legacy]));
        });
        Check([captured isEqualToString:
                          [NSString stringWithFormat:
                                            @"'%@' is a deprecated scope option; "
                                            @"falling back to 'All' behavior.\n\n",
                                            legacy]],
              ([NSString stringWithFormat:@"and warns on stderr about %@", legacy]));
        Check(configuration.testIdentifiersToRun == nil && configuration.testIdentifiersToSkip == nil,
              ([NSString stringWithFormat:@"and behaves as All (%@)", legacy]));
    }

    // An empty value is present, not absent. It is split into one empty component,
    // which the builder rejects -- and rejecting it is right: a domain that named a
    // scope and named it wrong is a different bug from having no opinion.
    if (RegisterScope(@"empty", @"", nil, nil)) {
        XCTestConfiguration *emptyScope = [[XCTestConfiguration alloc] init];
        NSError *error = nil;
        Check(![XCTestConfigurationLoader
                  applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                      commandLineArguments:@[]
                                        testConfiguration:emptyScope
                                                 outError:&error],
              @"an empty scope is an error rather than no opinion");
        Check(error.code == -500, @"reported as an unparseable identifier");
    }

    // A trailing comma is the typo people actually make, and it is caught by the
    // same rule that catches an empty scope: splitting "MyTests/testFoo," yields a
    // second component that is empty, and the builder has no reading for an empty
    // name. What is *not* claimed here is that a component which merely looks wrong
    // is rejected -- it is not, because the builder gives every non-empty string a
    // Swift Testing reading. Rejecting nonsense at the loader would mean holding a
    // second opinion about what a valid test name is, and this loader's job is to
    // pass the scope on and report what the builder said.
    if (RegisterScope(@"typo", @"MyTests/testFoo,", nil, nil)) {
        XCTestConfiguration *typo = [[XCTestConfiguration alloc] init];
        NSError *error = nil;
        Check(![XCTestConfigurationLoader
                  applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                      commandLineArguments:@[]
                                        testConfiguration:typo
                                                 outError:&error],
              @"a scope with a trailing comma is an error");
        Check([error.localizedDescription isEqualToString:@"Invalid test identifier: "],
              @"naming the component that did not parse");
        Check(typo.testIdentifiersToRun == nil, @"and nothing was applied on the way to failing");
    }

    // A component the builder will accept, however odd it looks. Asserted because
    // it is surprising and because a reader will otherwise assume the check above
    // was about nonsense: this is the honest shape of the rule.
    if (RegisterScope(@"odd-but-parseable", @"!! not one !!", nil, nil)) {
        XCTestConfiguration *odd = [[XCTestConfiguration alloc] init];
        NSError *error = nil;
        Check([XCTestConfigurationLoader
                  applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                      commandLineArguments:@[]
                                        testConfiguration:odd
                                                 outError:&error],
              @"a component that looks wrong but parses is the builder's to accept");
        Check(error == nil, @"and reports no error");
    }

    // No scope at all, and no unexpected arguments: success, and no change. Nothing
    // is registered, so the registration domain is empty for this check.
    XCTestConfiguration *noScope = [[XCTestConfiguration alloc] init];
    Check([XCTestConfigurationLoader
              applySettingsFromUserDefaultsIfApplicable:[NSUserDefaults standardUserDefaults]
                                  commandLineArguments:@[]
                                    testConfiguration:noScope
                                             outError:NULL],
          @"no scope and no extra arguments is success");
    Check(noScope.testIdentifiersToRun == nil, @"and leaves the selection alone");
}

/// A scope file written at `path`, with the given identifiers as its XCTestScope.
static BOOL WriteScopeFile(NSString *path, id scope, BOOL invert)
{
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    if (scope) {
        plist[@"XCTestScope"] = scope;
    }
    if (invert) {
        plist[@"XCTestInvertScope"] = @YES;
    }
    return WriteBytes(path, [NSPropertyListSerialization dataWithPropertyList:plist
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:NULL]);
}

static void ScenarioScopeFromFile(NSString *fixtures)
{
    if (ScopeKeysShadowed()) {
        Skip(@"a scope file is accepted", @"this account already has a scope");
        return;
    }
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];

    // The array form. This is the check that catches an implementation treating a
    // file's array as a comma-separated string: the entries below have no commas,
    // so splitting them would produce one entry that does not parse.
    NSString *scopeFile = [fixtures stringByAppendingPathComponent:@"scope.plist"];
    if (!WriteScopeFile(scopeFile, @[@"MyTests/testFoo", @"MyTests/testBar"], NO)) {
        Check(NO, @"fixture: a scope file could be written");
        return;
    }
    if (RegisterScope(@"file", nil, nil, scopeFile)) {
        XCTestConfiguration *configuration = [[XCTestConfiguration alloc] init];
        Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                             commandLineArguments:@[]
                                                               testConfiguration:configuration
                                                                        outError:NULL],
              @"a scope file is accepted");
        Check(configuration.testIdentifiersToRun.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo", @"MyTests/testBar" ]),
              @"and its XCTestScope array is taken element by element, not split");
    }

    // A file wins over a defaults value: a file is a deliberate act and a defaults
    // value is a leftover.
    if (RegisterScope(@"file-over-defaults", @"MyTests/fromDefaults", nil, scopeFile)) {
        XCTestConfiguration *both = [[XCTestConfiguration alloc] init];
        [XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                     commandLineArguments:@[]
                                                       testConfiguration:both
                                                            outError:NULL];
        Check(both.testIdentifiersToRun.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo", @"MyTests/testBar" ]),
              @"a scope file takes precedence over the XCTest value");
    }

    // The inversion is read from wherever the scope came. A scope file with no
    // inversion key is *not* inverted by a defaults key that happens to be set,
    // because reading it from both would let a leftover override a deliberate act.
    if (RegisterScope(@"file-invert-default", nil, @YES, scopeFile)) {
        XCTestConfiguration *uninverted = [[XCTestConfiguration alloc] init];
        [XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                     commandLineArguments:@[]
                                                       testConfiguration:uninverted
                                                            outError:NULL];
        Check(uninverted.testIdentifiersToRun.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo", @"MyTests/testBar" ]),
              @"a file with no inversion key ignores the XCTestInvertScope default");
        Check(uninverted.testIdentifiersToSkip == nil, @"and lands nothing in the skip list");
    }

    // The same file, with its own inversion key, does invert.
    NSString *invertingFile = [fixtures stringByAppendingPathComponent:@"scope-invert.plist"];
    if (WriteScopeFile(invertingFile, @[@"MyTests/testFoo"], YES) &&
        RegisterScope(@"file-invert-own", nil, nil, invertingFile)) {
        XCTestConfiguration *inverted = [[XCTestConfiguration alloc] init];
        [XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                     commandLineArguments:@[]
                                                       testConfiguration:inverted
                                                            outError:NULL];
        Check(inverted.testIdentifiersToSkip.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo" ]),
              @"a file's own XCTestInvertScope key inverts it");
    }

    // A file whose XCTestScope is absent is an empty selection, not an error: it
    // expressed no opinion about which tests run.
    NSString *noScopeKey = [fixtures stringByAppendingPathComponent:@"scope-absent.plist"];
    if (WriteScopeFile(noScopeKey, nil, NO) && RegisterScope(@"file-noscope", nil, nil, noScopeKey)) {
        XCTestConfiguration *noScope = [[XCTestConfiguration alloc] init];
        Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                             commandLineArguments:@[]
                                                               testConfiguration:noScope
                                                                        outError:NULL],
              @"a file with no XCTestScope key is not an error");
        Check(noScope.testIdentifiersToRun != nil && noScope.testIdentifiersToRun.count == 0,
              @"and selects the empty set");
    }

    // A plist that is not a dictionary is refused by name and class. The failure is
    // an assertion rather than an NSError, because it means the file is not what
    // the defaults value claimed it was -- which no caller can recover from by
    // trying a different scope.
    NSString *arrayPlist = [fixtures stringByAppendingPathComponent:@"scope-array.plist"];
    if (WriteBytes(arrayPlist, [NSPropertyListSerialization
                                    dataWithPropertyList:@[ @{@"XCTestScope": @[@"MyTests/testFoo"]} ]
                                                   format:NSPropertyListXMLFormat_v1_0
                                                  options:0
                                                    error:NULL]) &&
        RegisterScope(@"file-array", nil, nil, arrayPlist)) {
        XCTestConfiguration *refused = [[XCTestConfiguration alloc] init];
        BOOL raised = NO;
        @try {
            [XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                             commandLineArguments:@[]
                                                               testConfiguration:refused
                                                                        outError:NULL];
        } @catch (NSException *exception) {
            raised = YES;
            Check([exception.name isEqualToString:NSInternalInconsistencyException],
                  @"a non-dictionary scope file raises an inconsistency");
            Check([exception.reason containsString:@"non-NSDictionary"],
                  @"naming what was wrong with the plist");
        }
        if (!raised) {
            Check(NO, @"a non-dictionary scope file raises");
            Check(NO, @"naming what was wrong with the plist");
        }
    }

    // A file that is not there at all. Same reasoning as above: this is not
    // something a caller can retry around, so it raises rather than returning NO.
    if (RegisterScope(@"file-missing", nil, nil, [fixtures stringByAppendingPathComponent:@"absent.plist"])) {
        XCTestConfiguration *missing = [[XCTestConfiguration alloc] init];
        BOOL raised = NO;
        @try {
            [XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                             commandLineArguments:@[]
                                                               testConfiguration:missing
                                                                        outError:NULL];
        } @catch (NSException *exception) {
            raised = YES;
            Check([exception.reason containsString:@"Failed to read data from path"],
                  @"an unreadable scope file names the path it could not read");
        }
        if (!raised) {
            Check(NO, @"an unreadable scope file raises");
        }
    }
}

#pragma mark - The command-line fallback

static void ScenarioCommandLine(void)
{
    if (ScopeKeysShadowed()) {
        Skip(@"an unexpected argument is an error", @"this account already has a scope");
        return;
    }
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
    XCTestConfiguration *configuration = [[XCTestConfiguration alloc] init];

    // The array is 0-based like NSProcessInfo.arguments, with the program at
    // element 0. One real argument is the normal case and must not be read as
    // unrecognized.
    NSError *error = nil;
    Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                         commandLineArguments:@[ @"/usr/bin/xctest" ]
                                                           testConfiguration:configuration
                                                                    outError:&error],
          @"a lone program name is not an error");
    Check(error == nil, @"and reports none");

    // Still one real argument at two elements, which the reference tolerates: its
    // threshold is three. Reproduced rather than corrected, because a caller that
    // filters on the error has to match the runs it reproduces.
    error = nil;
    Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                         commandLineArguments:@[ @"/usr/bin/xctest",
                                                                                @"-only-testing:A" ]
                                                           testConfiguration:configuration
                                                                    outError:&error],
          @"one real argument is tolerated");
    Check(error == nil, @"and reports none");

    // Two real arguments trip the reference's threshold, and the message names
    // element 1 -- the *first* of the two.
    error = nil;
    Check(![XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                          commandLineArguments:@[ @"/usr/bin/xctest",
                                                                                 @"-only-testing:A",
                                                                                 @"-nonsense" ]
                                                            testConfiguration:configuration
                                                                     outError:&error],
          @"two real arguments are an error");
    Check([error.domain isEqualToString:@"XCTCommandLineToolDomain"], @"in the command line domain");
    Check(error.code == 3, @"with the reference's code");
    Check([error.localizedDescription isEqualToString:@"Unrecognized argument: -only-testing:A"],
          @"naming the first argument, not the last");

    // The error is the answer whether or not anyone asked for it, so a NULL
    // outError still fails.
    Check(![XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                          commandLineArguments:@[ @"/usr/bin/xctest",
                                                                                 @"-nonsense",
                                                                                 @"-more" ]
                                                            testConfiguration:configuration
                                                                     outError:NULL],
          @"a NULL outError still reports failure");

    // A scope in the environment means the command line was never consulted, even
    // when it holds arguments the loader does not recognize: the scope already
    // answers what runs, which is the question those arguments would have answered.
    if (RegisterScope(@"args-scoped", @"MyTests/testFoo", nil, nil)) {
        XCTestConfiguration *scopedConfiguration = [[XCTestConfiguration alloc] init];
        Check([XCTestConfigurationLoader applySettingsFromUserDefaultsIfApplicable:standard
                                                             commandLineArguments:@[ @"/usr/bin/xctest",
                                                                                    @"-nonsense",
                                                                                    @"-more" ]
                                                               testConfiguration:scopedConfiguration
                                                                        outError:NULL],
              @"a named scope suppresses the command-line check");
        Check(scopedConfiguration.testIdentifiersToRun.count ==
                  BuilderCountForIdentifiers(@[ @"MyTests/testFoo" ]),
              @"and the scope is what applies");
    }
}

#pragma mark - Settings reaching a discovered configuration

static void ScenarioSettingsReachDiscovery(NSString *fixtures)
{
    // The narrower claim, and the only one that can be made honestly: the loader
    // reads the *standard* defaults domain, which a harness cannot replace. So
    // with no scope named in the standard domain, a discovered configuration must
    // be left unselected -- and where the developer's own domain does have a scope,
    // this says so instead of pretending to have proved it.
    if (!WriteTemporaryConfiguration(@"settings.xctestconfiguration",
                                     ConfigurationTagged(@"settings"))) {
        Check(NO, @"fixture: a configuration could be archived");
        return;
    }
    SetModificationDate(TemporaryPath(@"settings.xctestconfiguration"), 0);

    if (ScopeKeysShadowed()) {
        Skip(@"discovery applies no scope when none is named", @"this account already has a scope");
        return;
    }

    XCTestConfiguration *configuration = [LoaderNamingNothing() loadTestConfiguration];
    Check(configuration != nil, @"discovery still finds the configuration");
    Check(configuration.testIdentifiersToRun == nil && configuration.testIdentifiersToSkip == nil,
          @"and applies no scope of its own when none was named");
    (void)fixtures;
}

#pragma mark - Dispatch

int main(int argc, const char *argv[])
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <scenario> <fixtures-directory> <run-prefix>\n", argv[0]);
        return 2;
    }
    NSString *scenario = [NSString stringWithUTF8String:argv[1]];
    NSString *fixtures = [NSString stringWithUTF8String:argv[2]];
    runPrefix = [NSString stringWithUTF8String:argv[3]];

    // Registered before anything is written rather than after, so a scenario that
    // dies part way through still leaves nothing in the account's temporary
    // directory.
    atexit(RemoveCreatedTemporaryPaths);

    @autoreleasepool {
        fprintf(stdout, "%s\n", scenario.UTF8String);
        if ([scenario isEqualToString:@"encoded"]) {
            ScenarioEncodedValue(fixtures);
        } else if ([scenario isEqualToString:@"path"]) {
            ScenarioPathSource(fixtures);
        } else if ([scenario isEqualToString:@"relative"]) {
            ScenarioRelativePath(fixtures);
        } else if ([scenario isEqualToString:@"precedence"]) {
            ScenarioPrecedence(fixtures);
        } else if ([scenario isEqualToString:@"discovery-order"]) {
            ScenarioDiscoveryOrder(fixtures);
        } else if ([scenario isEqualToString:@"discovery-none"]) {
            ScenarioDiscoveryNone(fixtures);
        } else if ([scenario isEqualToString:@"reporting"]) {
            ScenarioReporting(fixtures);
        } else if ([scenario isEqualToString:@"init"]) {
            ScenarioInitFromEnvironment(fixtures);
        } else if ([scenario isEqualToString:@"identifiers"]) {
            ScenarioIdentifierSet();
        } else if ([scenario isEqualToString:@"scope-defaults"]) {
            ScenarioScopeFromDefaults(fixtures);
        } else if ([scenario isEqualToString:@"scope-file"]) {
            ScenarioScopeFromFile(fixtures);
        } else if ([scenario isEqualToString:@"command-line"]) {
            ScenarioCommandLine();
        } else if ([scenario isEqualToString:@"settings-discovery"]) {
            ScenarioSettingsReachDiscovery(fixtures);
        } else {
            fprintf(stderr, "unknown scenario: %s\n", scenario.UTF8String);
            return 2;
        }

        fprintf(stdout, "  %d failure(s) of %lu check(s)\n\n", (int)checksFailed, (unsigned long)checksRun);
    }
    return checksFailed == 0 ? 0 : 1;
}
