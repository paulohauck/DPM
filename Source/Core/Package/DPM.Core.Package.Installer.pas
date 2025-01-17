{***************************************************************************}
{                                                                           }
{           Delphi Package Manager - DPM                                    }
{                                                                           }
{           Copyright � 2019 Vincent Parrett and contributors               }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit DPM.Core.Package.Installer;

//TODO : Lots of common code between install and restore - refactor!

interface

uses
  Spring.Collections,
  DPM.Core.Types,
  DPM.Core.Logging,
  DPM.Core.Options.Cache,
  DPM.Core.Options.Install,
  DPM.Core.Options.Restore,
  DPM.Core.Project.Interfaces,
  DPM.Core.Package.Interfaces,
  DPM.Core.Configuration.Interfaces,
  DPM.Core.Repository.Interfaces,
  DPM.Core.Cache.Interfaces,
  DPM.Core.Dependency.Interfaces;

type
  TPackageInstaller = class(TInterfacedObject, IPackageInstaller)
  private
    FLogger : ILogger;
    FConfigurationManager : IConfigurationManager;
    FRepositoryManager : IPackageRepositoryManager;
    FPackageCache : IPackageCache;
    FDependencyResolver : IDependencyResolver;
    FLockFileReader : ILockFileReader;
    FContext : IPackageInstallerContext;
  protected
    function GetPackageInfo(const packageIndentity: IPackageIdentity): IPackageInfo;

    function CollectSearchPaths(const resolvedPackages : IList<IPackageInfo>; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const searchPaths : IList<string>) : boolean;

    function DownloadPackages(const resolvedPackages : IList<IPackageInfo>) : boolean;

    function CollectPlatformsFromProjectFiles(const options: TInstallOptions; const projectFiles : TArray<string>; const config : IConfiguration) : boolean;

    function GetCompilerVersionFromProjectFiles(const options: TInstallOptions; const projectFiles : TArray<string>; const config : IConfiguration) : boolean;


    function DoRestoreProject(const options: TRestoreOptions; const projectFile : string; const projectEditor : IProjectEditor;  const platform : TDPMPlatform; const config : IConfiguration) : boolean;

    function DoInstallPackage(const options: TInstallOptions; const projectFile : string; const projectEditor : IProjectEditor;  const platform : TDPMPlatform; const config : IConfiguration) : boolean;

    function DoCachePackage(const options : TCacheOptions; const platform : TDPMPlatform) : boolean;

    //works out what compiler/platform then calls DoInstallPackage
    function InstallPackage(const options: TInstallOptions; const projectFile : string; const config : IConfiguration) : boolean;

    //user specified a package file - will install for single compiler/platform - calls InstallPackage
    function InstallPackageFromFile(const options: TInstallOptions; const projectFiles : TArray<string>; const config : IConfiguration) : boolean;

    //resolves package from id - calls InstallPackage
    function InstallPackageFromId(const options: TInstallOptions; const projectFiles : TArray<string>; const config : IConfiguration) : boolean;

    //calls either InstallPackageFromId or InstallPackageFromFile depending on options.
    function Install(const options: TInstallOptions): Boolean;

    function RestoreProject(const options: TRestoreOptions; const projectFile : string; const config : IConfiguration): Boolean;

    //calls restore project
    function Restore(const options: TRestoreOptions): Boolean;

    function Cache(const options : TCacheOptions) : boolean;
  public
    constructor Create(const logger :ILogger; const configurationManager : IConfigurationManager;
                       const repositoryManager : IPackageRepositoryManager; const packageCache : IPackageCache;
                       const dependencyResolver : IDependencyResolver; const lockFileReader : ILockFileReader;
                       const context : IPackageInstallerContext);
  end;

implementation

uses
  System.IOUtils,
  System.Types,
  System.SysUtils,
  DPM.Core.Constants,
  DPM.Core.Utils.System,
  DPM.Core.Project.Editor,
  DPM.Core.Project.GroupProjReader,
  DPM.Core.Project.PackageReference,
  DPM.Core.Options.List,
  DPM.Core.Package.Metadata,
  DPM.Core.Spec.Interfaces,
  DPM.Core.Spec.Reader;


{ TPackageInstaller }


function TPackageInstaller.Cache(const options: TCacheOptions): boolean;
var
  config    : IConfiguration;
  platform  : TDPMPlatform;
  platforms : TDPMPlatforms;
begin
  result := false;
  if (not options.Validated) and (not options.Validate(FLogger)) then
      exit
  else if not options.IsValid then
    exit;

  config := FConfigurationManager.LoadConfig(options.ConfigFile);
  if config = nil then
    exit;

  FPackageCache.Location := config.PackageCacheLocation;
  if not FRepositoryManager.Initialize(config) then
  begin
    FLogger.Error('Unable to initialize the repository manager.');
    exit;
  end;

  platforms := options.Platforms;

  if platforms = [] then
    platforms := AllPlatforms(options.CompilerVersion);

  result := true;
  for platform in platforms do
  begin
    options.Platforms := [platform];
    result := DoCachePackage(options, platform) and result;
  end;
end;

function TPackageInstaller.CollectPlatformsFromProjectFiles(const options: TInstallOptions; const projectFiles: TArray<string>; const config : IConfiguration): boolean;
var
  projectFile : string;
  projectEditor : IProjectEditor;
begin
  result := true;
  for projectFile in projectFiles do
  begin
    projectEditor := TProjectEditor.Create(FLogger, config);
    result := result and projectEditor.LoadProject(projectFile);
    if result then
      options.Platforms := options.Platforms + projectEditor.Platforms;
  end;

end;

function TPackageInstaller.CollectSearchPaths(const resolvedPackages : IList<IPackageInfo>; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const searchPaths : IList<string>) : boolean;
var
  packageInfo : IPackageInfo;
  packageMetadata : IPackageMetadata;
  packageSearchPath : IPackageSearchPath;
  packageBasePath : string;
begin
  result := true;

  for packageInfo in resolvedPackages do
  begin
    packageMetadata := FPackageCache.GetPackageMetadata(packageInfo);
    if packageMetadata = nil then
    begin
      FLogger.Error('Unable to get metadata for package ' + packageInfo.ToString);
      exit(false);
    end;
    packageBasePath := packageMetadata.Id + PathDelim + packageMetadata.Version.ToStringNoMeta + PathDelim;

    for packageSearchPath in packageMetadata.SearchPaths do
      searchPaths.Add( packageBasePath + packageSearchPath.Path);
  end;
end;

constructor TPackageInstaller.Create(const logger: ILogger; const configurationManager : IConfigurationManager;
                                     const repositoryManager : IPackageRepositoryManager; const packageCache : IPackageCache;
                                     const dependencyResolver : IDependencyResolver; const lockFileReader : ILockFileReader;
                                     const context : IPackageInstallerContext);
begin
  FLogger               := logger;
  FConfigurationManager := configurationManager;
  FRepositoryManager    := repositoryManager;
  FPackageCache         := packageCache;
  FDependencyResolver   := dependencyResolver;
  FLockFileReader       := lockFileReader;
  FContext              := context;
end;

function GetLockFileName(const projectFileName : string; const platform : TDPMPlatform) : string;
begin
  result := projectFileName + '.' + DPMPlatformToString(platform) + cLockFileExt;
end;

function TPackageInstaller.GetPackageInfo(const packageIndentity : IPackageIdentity) : IPackageInfo;
begin
  result := FPackageCache.GetPackageInfo(packageIndentity); //faster
  if result = nil then
    result := FRepositoryManager.GetPackageInfo(packageIndentity); //slower
end;

function TPackageInstaller.DoCachePackage(const options: TCacheOptions; const platform: TDPMPlatform): boolean;
var
  packageIdentity : IPackageIdentity;
  searchResult : IPackageSearchResult;
  packageFileName : string;
begin
  result := false;
  if not options.Version.IsEmpty then
    //sourceName will be empty if we are installing the package from a file
    packageIdentity := TPackageIdentity.Create(options.PackageId, '', options.Version, options.CompilerVersion, platform)
  else
  begin
    //no version specified, so we need to get the latest version available;
    searchResult := FRepositoryManager.Search(options);
    packageIdentity := searchResult.Packages.FirstOrDefault;
    if packageIdentity = nil then
    begin
      FLogger.Error('Package [' + options.PackageId + '] for platform [' + DPMPlatformToString(platform) + '] not found on any sources');
      exit;
    end;
  end;
  FLogger.Information('Caching package ' + packageIdentity.ToString);

  if not FPackageCache.EnsurePackage(packageIdentity) then
  begin
    //not in the cache, so we need to get it from the the repository
    if not FRepositoryManager.DownloadPackage(packageIdentity, FPackageCache.PackagesFolder, packageFileName ) then
    begin
      FLogger.Error('Failed to download package [' + packageIdentity.ToString + ']' );
      exit;
    end;
    if not FPackageCache.InstallPackageFromFile(packageFileName, true) then
    begin
      FLogger.Error('Failed to cache package file [' + packageFileName + '] into the cache' );
      exit;
    end;
  end;
  result := true;

end;

function TPackageInstaller.DoInstallPackage(const options: TInstallOptions; const projectFile: string; const projectEditor: IProjectEditor; const platform: TDPMPlatform; const config : IConfiguration): boolean;
var
  packageIdentity : IPackageIdentity;
  searchResult : IPackageSearchResult;
  packageFileName : string;
  packageInfo : IPackageInfo; //includes dependencies;
  existingPackageRef : IPackageReference;
  packageReferences : IList<IPackageReference>;
  packageIdentities  : IList<IPackageIdentity>;
  projectPackageInfos : IList<IPackageInfo>;
  lockFileName : string;
  lockFile : ILockFile;
  projectPackageInfo : IPackageInfo;
  resolvedPackages : IList<IPackageInfo>;
  packageSearchPaths : IList<string>;
  newPackageReference : IPackageReference;
begin
  result := false;
  //if the user specified a version, either the on the command line or via a file then we will use that
  if not options.Version.IsEmpty then
    //sourceName will be empty if we are installing the package from a file
    packageIdentity := TPackageIdentity.Create(options.PackageId, '', options.Version, options.CompilerVersion, platform)
  else
  begin
    //no version specified, so we need to get the latest version available;
    searchResult := FRepositoryManager.Search(options);
    packageIdentity := searchResult.Packages.FirstOrDefault;
    if packageIdentity = nil then
    begin
      FLogger.Error('Package [' + options.PackageId + '] for platform [' + DPMPlatformToString(platform) + '] not found on any sources');
      exit;
    end;
  end;
  FLogger.Information('Installing package ' + packageIdentity.ToString);

  //get the packages already referenced by the project for the platform
  packageReferences := TCollections.CreateList<IPackageReference>;
  packageReferences.AddRange(projectEditor.PackageReferences.Where(
    function(const packageReference : IPackageReference) : boolean
    begin
      result := platform = packageReference.Platform;
    end));


  //check to ensure we are not trying to install something that is already installed.
  existingPackageRef := packageReferences.Where(
    function(const packageRef : IPackageReference) : boolean
    begin
      result := SameText(packageIdentity.Id, packageRef.Id);
      result := result and (packageIdentity.Platform = packageRef.Platform);
    end).FirstOrDefault;


  if (existingPackageRef <> nil)   then
  begin
    if not options.Force then
    begin
      FLogger.Error('Package [' + packageIdentity.ToString + '] is already installed. Use option -force to force reinstall.');
      exit;
    end
    else
      packageReferences.Remove(existingPackageRef);
  end;


  if not FPackageCache.EnsurePackage(packageIdentity) then
  begin
    //not in the cache, so we need to get it from the the repository
    if not FRepositoryManager.DownloadPackage(packageIdentity, FPackageCache.PackagesFolder, packageFileName ) then
    begin
      FLogger.Error('Failed to download package [' + packageIdentity.ToString + ']' );
      exit;
    end;
    if not FPackageCache.InstallPackageFromFile(packageFileName, true) then
    begin
      FLogger.Error('Failed to install package file [' + packageFileName + '] into the cache' );
      exit;
    end;
  end;

  //get the package info, which has the dependencies.
  packageInfo := GetPackageInfo(packageIdentity);


  //turn them into packageIdentity's so we can get their Info/dependencies
  packageIdentities := TCollections.CreateList<IPackageIdentity>;
  packageIdentities.AddRange(TEnumerable.Select<IPackageReference, IPackageIdentity>(packageReferences,
    function(packageReference : IPackageReference) : IPackageIdentity
    begin
      result := TPackageIdentity.Create(packageReference.Id,'', packageReference.Version, options.CompilerVersion, platform);
    end));

  projectPackageInfos := TCollections.CreateList<IPackageInfo>;
  for packageIdentity in packageIdentities do
  begin
    projectPackageInfo := GetPackageInfo(packageIdentity);
    if projectPackageInfo = nil then
    begin
      FLogger.Error('Unable to resolve package [' + packageIdentity.ToString + ']');
      exit;
    end;
    projectPackageInfos.Add(projectPackageInfo);
  end;



  lockFileName := GetLockFileName(projectFile, platform);
  if FileExists(lockFileName) then
  begin
    if not FLockFileReader.TryLoadFromFile(lockFileName, lockFile) then
    begin
      FLogger.Error('Unable to load lock file, it may be corrupted');
      exit;
    end;
  end
  else //no lock file, so start a new graph.
    lockFile := FLockFileReader.CreateNew(lockFileName);

  result := FDependencyResolver.ResolveForInstall(options, packageInfo,projectPackageInfos, lockFile.Graph, packageInfo.CompilerVersion, platform, resolvedPackages );
  if not result then
    exit;

  if resolvedPackages = nil then
  begin
    FLogger.Error('Resolver returned no packages!');
    exit(false);
  end;

  packageInfo := resolvedPackages.Where(
      function(const info : IPackageInfo) : boolean
      begin
        result := SameText(info.Id, packageInfo.Id);
      end).FirstOrDefault;

  if packageInfo = nil then
  begin
    FLogger.Error('Something went wrong, resultution did not return installed package!' );
    exit(false);
  end;

  result := DownloadPackages(resolvedPackages);
  if not result then
    exit;

  packageSearchPaths := TCollections.CreateList<string>;

  if not CollectSearchPaths(resolvedPackages, projectEditor.CompilerVersion, platform, packageSearchPaths) then
    exit;

  if not projectEditor.AddSearchPaths(platform, packageSearchPaths, config.PackageCacheLocation) then
    exit;

  newPackageReference := TPackageReference.Create(packageInfo.Id, packageInfo.Version, platform);

  if not projectEditor.AddOrUpdatePackageReference(newPackageReference) then
    exit;

  result := projectEditor.SaveProject();


end;

function TPackageInstaller.DoRestoreProject(const options: TRestoreOptions; const projectFile: string; const projectEditor: IProjectEditor; const platform: TDPMPlatform; const config : IConfiguration): boolean;
var
  packageIdentity : IPackageIdentity;
  packageReferences : IList<IPackageReference>;
  packageIdentities  : IList<IPackageIdentity>;
  projectPackageInfos : IList<IPackageInfo>;
  lockFileName : string;
  lockFile : ILockFile;
  projectPackageInfo : IPackageInfo;
  resolvedPackages : IList<IPackageInfo>;
  packageSearchPaths : IList<string>;
begin
  result := false;

  //get the packages already referenced by the project for the platform
  packageReferences := TCollections.CreateList<IPackageReference>;
  packageReferences.AddRange(projectEditor.PackageReferences.Where(
    function(const packageReference : IPackageReference) : boolean
    begin
      result := platform = packageReference.Platform;
    end));

  if not packageReferences.Any then
  begin
    FLogger.Information('No package references found in project [' + projectFile + '] for platform [' + DPMPlatformToString(platform) + ']' );
    //TODO : Should this fail with an error? It's a noop
    exit(true);
  end;

  //turn them into packageIdentity's so we can get their Info/dependencies
  packageIdentities := TCollections.CreateList<IPackageIdentity>;
  packageIdentities.AddRange(TEnumerable.Select<IPackageReference, IPackageIdentity>(packageReferences,
    function(packageReference : IPackageReference) : IPackageIdentity
    begin
      result := TPackageIdentity.Create(packageReference.Id,'', packageReference.Version, options.CompilerVersion, platform);
    end));



  projectPackageInfos := TCollections.CreateList<IPackageInfo>;
  for packageIdentity in packageIdentities do
  begin
    projectPackageInfo := GetPackageInfo(packageIdentity);
    if projectPackageInfo = nil then
    begin
      FLogger.Error('Unable to resolve package [' + packageIdentity.ToString + ']');
      exit;
    end;
    projectPackageInfos.Add(projectPackageInfo);
  end;

  lockFileName := GetLockFileName(projectFile, platform);
  if FileExists(lockFileName) then
  begin
    if not FLockFileReader.TryLoadFromFile(lockFileName, lockFile) then
    begin
      FLogger.Error('Unable to load lock file, it may be corrupted');
      exit;
    end;
  end
  else //no lock file, so start a new graph.
    lockFile := FLockFileReader.CreateNew(lockFileName);

  result := FDependencyResolver.ResolveForRestore(options, projectPackageInfos, lockFile.Graph, options.CompilerVersion, platform, resolvedPackages );
  if not result then
    exit;

  if resolvedPackages = nil then
  begin
    FLogger.Error('Resolver returned no packages!');
    exit(false);
  end;

  result := DownloadPackages(resolvedPackages);
  if not result then
    exit;

  packageSearchPaths := TCollections.CreateList<string>;
  if not CollectSearchPaths(resolvedPackages, projectEditor.CompilerVersion, platform, packageSearchPaths) then
    exit;

  result := projectEditor.AddSearchPaths(platform, packageSearchPaths, config.PackageCacheLocation);
  if result then
    result := projectEditor.SaveProject();


end;

function TPackageInstaller.DownloadPackages(const resolvedPackages: IList<IPackageInfo>): boolean;
var
  packageInfo : IPackageInfo;
  packageFileName : string;
begin
  result := false;

  for packageInfo in resolvedPackages do
  begin
    if not FPackageCache.EnsurePackage(packageInfo) then
    begin
      //not in the cache, so we need to get it from the the repository
      if not FRepositoryManager.DownloadPackage(packageInfo, FPackageCache.PackagesFolder, packageFileName ) then
      begin
        FLogger.Error('Failed to download package [' + packageInfo.ToString + ']' );
        exit;
      end;
      if not FPackageCache.InstallPackageFromFile(packageFileName, true) then
      begin
        FLogger.Error('Failed to install package file [' + packageFileName + '] into the cache' );
        exit;
      end;
    end;
  end;
  result := true;

end;

function TPackageInstaller.InstallPackage(const options: TInstallOptions; const projectFile : string; const config : IConfiguration) : boolean;
var
  projectEditor : IProjectEditor;
  platforms : TDPMPlatforms;
  platform : TDPMPlatform;
  platformResult : boolean;
  ambiguousProjectVersion : boolean;
begin
  result := false;

  //make sure we can parse the dproj
  projectEditor := TProjectEditor.Create(FLogger, config);
  if not projectEditor.LoadProject(projectFile) then
  begin
    FLogger.Error('Unable to load project file, cannot continue');
    exit;
  end;

  ambiguousProjectVersion := IsAmbigousProjectVersion(projectEditor.ProjectVersion);

  if ambiguousProjectVersion and (options.CompilerVersion = TCompilerVersion.UnknownVersion) then
     FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] is ambiguous, recommend specifying compiler on command line.');

  //if the compiler version was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that version.
  if options.CompilerVersion <> TCompilerVersion.UnknownVersion then
  begin
    if projectEditor.CompilerVersion <> options.CompilerVersion then
    begin
      if not ambiguousProjectVersion then
        FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] does not match the compiler version.');
    end;
  end
  else
    options.CompilerVersion := projectEditor.CompilerVersion;


  //if the platform was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that platform.
  if options.Platforms <> [] then
  begin
    platforms :=  options.Platforms * projectEditor.Platforms; //gets the intersection of the two sets.
    if platforms = [] then //no intersection
    begin
      FLogger.Warning('Skipping project file [' + projectFile + '] as it does not match target specified platforms.');
      exit;
    end;
    //TODO : what if only some of the platforms are supported, what should we do?
  end
  else
    platforms := projectEditor.Platforms;

  for platform in platforms do
  begin
    options.Platforms := [platform];
    FLogger.Information('Attempting install [' + options.SearchTerms + '-' + DPMPlatformToString(platform) + '] into [' + projectFile + ']', true);
    platformResult  := DoInstallPackage(options, projectFile, projectEditor, platform, config);
    if not platformResult then
      FLogger.Error('Install failed for [' + options.SearchTerms + '-' + DPMPlatformToString(platform) + ']');
    result := platformResult and result;
    FLogger.Information('');
  end;

end;

function TPackageInstaller.GetCompilerVersionFromProjectFiles(const options: TInstallOptions; const projectFiles: TArray<string>; const config : IConfiguration): boolean;
var
  projectFile : string;
  projectEditor : IProjectEditor;
  compilerVersion : TCompilerVersion;
  bFirst : boolean;
begin
  result := true;
  compilerVersion := TCompilerVersion.UnknownVersion;
  bFirst := true;
  for projectFile in projectFiles do
  begin
    projectEditor := TProjectEditor.Create(FLogger, config);
    result := result and projectEditor.LoadProject(projectFile);
    if result then
    begin
      if not bFirst then
      begin
        if projectEditor.CompilerVersion <> compilerVersion then
        begin
          FLogger.Error('Projects are not all the for same compiler version.' );
          result := false;
        end;
      end;
      compilerVersion := options.CompilerVersion;
      options.CompilerVersion := projectEditor.CompilerVersion;
      bFirst := false;
    end;
  end;
end;

function TPackageInstaller.Install(const options: TInstallOptions): Boolean;
var
  projectFiles : TArray<string>;
  config       : IConfiguration;
begin
  result := false;
  if (not options.Validated) and (not options.Validate(FLogger)) then
      exit
  else if not options.IsValid then
    exit;

  config := FConfigurationManager.LoadConfig(options.ConfigFile);
  if config = nil then
    exit;

  FPackageCache.Location := config.PackageCacheLocation;
  if not FRepositoryManager.Initialize(config) then
  begin
    FLogger.Error('Unable to initialize the repository manager.');
    exit;
  end;


  if FileExists(options.ProjectPath) then
  begin
    if ExtractFileExt(options.ProjectPath) <> '.dproj' then
    begin
      FLogger.Error('Unsupported project file type [' + options.ProjectPath + ']');
    end;
    SetLength(projectFiles,1);
    projectFiles[0] := options.ProjectPath;

  end
  else if DirectoryExists(options.ProjectPath) then
  begin
    projectFiles := TArray<string>(TDirectory.GetFiles(options.ProjectPath, '*.dproj'));
    if Length(projectFiles) = 0 then
    begin
      FLogger.Error('No dproj files found in projectPath : ' + options.ProjectPath );
      exit;
    end;
    FLogger.Information('Found ' + IntToStr(Length(projectFiles)) + ' dproj file(s) to install into.' );
  end
  else
  begin
    //should never happen when called from the commmand line, but might from the IDE plugin.
    FLogger.Error('The projectPath provided does no exist, no project to install to');
    exit;
  end;

  if options.PackageFile <> '' then
  begin
    if not FileExists(options.PackageFile) then
    begin
      //should never happen if validation is called on the options.
      FLogger.Error('The specified packageFile [' + options.PackageFile + '] does not exist.');
      exit;
    end;
    result := InstallPackageFromFile(options, TArray<string>(projectFiles), config);
  end
  else
    result := InstallPackageFromId(options, TArray<string>(projectFiles), config);

end;

function TPackageInstaller.InstallPackageFromFile(const options: TInstallOptions; const projectFiles : TArray<string>; const config : IConfiguration): boolean;
var
  packageIdString : string;
  packageIdentity : IPackageIdentity;
  projectFile : string;
begin
  //get the package into the cache first then just install as normal
  result := FPackageCache.InstallPackageFromFile(options.PackageFile, true);
  if not result then
    exit;

  //get the identity so we can get the compiler version
  packageIdString := ExtractFileName(options.PackageFile);
  packageIdString := ChangeFileExt(packageIdString,'');
  if not TPackageIdentity.TryCreateFromString(FLogger, packageIdString, '', packageIdentity) then
    exit;

  //update options so we can install from the packageid.
  options.PackageFile := '';
  options.PackageId := packageIdentity.Id + '.' + packageIdentity.Version.ToStringNoMeta;
  options.CompilerVersion := packageIdentity.CompilerVersion; //package file is for single compiler version
  options.Platforms := [packageIdentity.Platform]; //package file is for single platform.

  FContext.Reset;
  try
    for projectFile in projectFiles do
      result := InstallPackage(options, projectFile, config) and result;

  finally
    FContext.Reset; //free up memory as this might be used in the IDE
  end;

end;

function TPackageInstaller.InstallPackageFromId(const options: TInstallOptions; const projectFiles: TArray<string>; const config : IConfiguration): boolean;
var
  projectFile : string;
begin
  result := true;
  FContext.Reset;
  try
    for projectFile in projectFiles do
      result := InstallPackage(options, projectFile, config) and result;
  finally
    FContext.Reset;
  end;
end;

function TPackageInstaller.Restore(const options: TRestoreOptions): Boolean;
var
  projectFiles : TArray<string>;
  projectFile  : string;
  config       : IConfiguration;
  groupProjReader : IGroupProjectReader;
  projectList : IList<string>;
begin
  result := false;
  //commandline would have validated already, but IDE probably not.
  if (not options.Validated) and (not options.Validate(FLogger)) then
      exit
  else if not options.IsValid then
    exit;

  config := FConfigurationManager.LoadConfig(options.ConfigFile);
  if config = nil then //no need to log, config manager will
    exit;

  FPackageCache.Location := config.PackageCacheLocation;
  if not FRepositoryManager.Initialize(config) then
  begin
    FLogger.Error('Unable to initialize the repository manager.');
    exit;
  end;

  if FileExists(options.ProjectPath) then
  begin
    //TODO : If we are using a groupProj then we shouldn't allow different versions of a package in different projects
    //need to work out how to detect this.

    if ExtractFileExt(options.ProjectPath) = '.groupproj' then
    begin
      groupProjReader := TGroupProjectReader.Create(FLogger);
      if not groupProjReader.LoadGroupProj(options.ProjectPath) then
        exit;

      projectList := TCollections.CreateList<string>;
      if not groupProjReader.ExtractProjects(projectList) then
        exit;
      projectFiles := projectList.ToArray;
    end
    else
    begin
      SetLength(projectFiles,1);
      projectFiles[0] := options.ProjectPath;
    end;
  end
  else if DirectoryExists(options.ProjectPath) then
  begin
    //todo : add groupproj support!
    projectFiles := TArray<string>(TDirectory.GetFiles(options.ProjectPath, '*.dproj'));
    if Length(projectFiles) = 0 then
    begin
      FLogger.Error('No project files found in projectPath : ' + options.ProjectPath );
      exit;
    end;
    FLogger.Information('Found ' + IntToStr(Length(projectFiles)) + ' project file(s) to restore.' );
  end
  else
  begin
    //should never happen when called from the commmand line, but might from the IDE plugin.
    FLogger.Error('The projectPath provided does no exist, no project to install to');
    exit;
  end;

  result := true;
  //TODO : create some sort of context object here to pass in so we can collect runtime/design time packages
  for projectFile in projectFiles do
    result := RestoreProject(options, projectFile, config) and result;
end;

function TPackageInstaller.RestoreProject(const options: TRestoreOptions; const projectFile : string; const config : IConfiguration): Boolean;
var
  projectEditor : IProjectEditor;
  platforms : TDPMPlatforms;
  platform : TDPMPlatform;
  platformResult : boolean;
  ambiguousProjectVersion : boolean;
begin
  result := false;

  //make sure we can parse the dproj
  projectEditor := TProjectEditor.Create(FLogger, config);
  if not projectEditor.LoadProject(projectFile) then
  begin
    FLogger.Error('Unable to load project file, cannot continue');
    exit;
  end;

  ambiguousProjectVersion := IsAmbigousProjectVersion(projectEditor.ProjectVersion);

  if ambiguousProjectVersion and (options.CompilerVersion = TCompilerVersion.UnknownVersion) then
     FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] is ambiguous, recommend specifying compiler on command line.');

  //if the compiler version was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that version.
  if options.CompilerVersion <> TCompilerVersion.UnknownVersion then
  begin
    if projectEditor.CompilerVersion <> options.CompilerVersion then
    begin
      if not ambiguousProjectVersion then
        FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] does not match the compiler version.');
    end;
  end
  else
    options.CompilerVersion := projectEditor.CompilerVersion;

  //if the platform was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that platform.
  if options.Platforms <> [] then
  begin
    platforms :=  options.Platforms * projectEditor.Platforms; //gets the intersection of the two sets.
    if platforms = [] then //no intersection
    begin
      FLogger.Warning('Skipping project file [' + projectFile + '] as it does not match specified platforms.');
      exit;
    end;
    //TODO : what if only some of the platforms are supported, what should we do?
  end
  else
    platforms := projectEditor.Platforms;

  for platform in platforms do
  begin
    options.Platforms := [platform];
    FLogger.Information('Attempting restore on [' + projectFile +'] for [' + DPMPlatformToString(platform) + ']', true);
    platformResult  := DoRestoreProject(options, projectFile, projectEditor, platform, config);
    if not platformResult then
      FLogger.Error('Restore failed for ' + DPMPlatformToString(platform));
    result := platformResult and result;
    FLogger.Information('');
  end;
end;

end.
