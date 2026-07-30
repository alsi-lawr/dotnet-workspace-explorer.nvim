#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
scratch=${DWE_SCRATCH_ROOT:-"$root/.agent-workspace/DWE-008"}
fixture="$scratch/fixture"

case "$fixture" in
	"$root"/.agent-workspace/*) ;;
	*) echo "fixture must stay under $root/.agent-workspace" >&2; exit 1 ;;
esac

rm -rf "$fixture"
mkdir -p \
	"$fixture/src/Studio.CSharp/Actions" \
	"$fixture/src/Studio.CSharp/Models" \
	"$fixture/src/Studio.FSharp/Foundation" \
	"$fixture/src/Studio.FSharp/Features" \
	"$fixture/src/Studio.VisualBasic/Presentation" \
	"$fixture/src/Studio.VisualBasic/Services"

cat >"$fixture/SemanticStudio.slnx" <<'EOF'
<Solution>
  <Folder Name="/src/">
    <Project Path="src/Studio.VisualBasic/Studio.VisualBasic.vbproj" Type="Visual Basic" />
  </Folder>
  <Folder Name="/src/Applications/">
    <Project Path="src/Studio.CSharp/Studio.CSharp.csproj" Type="C#" />
    <Project Path="src/Studio.FSharp/Studio.FSharp.fsproj" Type="F#" />
  </Folder>
</Solution>
EOF

cat >"$fixture/src/Studio.CSharp/Studio.CSharp.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="System.Collections.Immutable" Version="10.0.0" />
    <ProjectReference Include="../Studio.FSharp/Studio.FSharp.fsproj" />
    <Reference Include="System.Xml" />
  </ItemGroup>
</Project>
EOF

for name in \
	AddDocument \
	AddProject \
	CloseWorkspace \
	CollapseAll \
	CreateSolutionFolder \
	CreateWorkspace \
	DeleteDocument \
	ExpandAll \
	FocusExplorer \
	MoveDocument \
	OpenDocument \
	OpenWorkspace \
	RefreshDependencies \
	RefreshWorkspace \
	ReloadProject \
	RemoveProject \
	RenameDocument \
	RenameProject \
	RevealActiveDocument \
	SaveWorkspace \
	SelectProject \
	ShowDependencies \
	ShowProperties \
	SortProjects \
	SyncActiveDocument \
	TogglePreview \
	UnloadProject \
	UpdatePackage \
	ValidateWorkspace \
	WatchWorkspace \
	WorkspaceHistory \
	WorkspaceSearch
do
	printf 'namespace Studio.CSharp.Actions; internal sealed class %s { }\\n' "$name" \
		>"$fixture/src/Studio.CSharp/Actions/$name.cs"
done
for name in ProjectNode SolutionNode WorkspaceNode; do
	printf 'namespace Studio.CSharp.Models; internal sealed record %s;\\n' "$name" \
		>"$fixture/src/Studio.CSharp/Models/$name.cs"
done
printf 'namespace Studio.CSharp; internal static class Bootstrap { }\\n' \
	>"$fixture/src/Studio.CSharp/Bootstrap.cs"

cat >"$fixture/src/Studio.FSharp/Studio.FSharp.fsproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Foundation/Types.fs" />
    <Compile Include="Foundation/Contracts.fs" />
    <Compile Include="Features/LoadWorkspace.fs" />
    <Compile Include="Features/ExpandNode.fs" />
    <Compile Include="Features/RefreshTree.fs" />
    <Compile Include="Features/AddProjectItem.fs" />
    <Compile Include="Program.fs" />
    <PackageReference Include="FSharp.Core" Version="10.0.100" />
  </ItemGroup>
</Project>
EOF

for file in \
	Foundation/Types.fs \
	Foundation/Contracts.fs \
	Features/LoadWorkspace.fs \
	Features/ExpandNode.fs \
	Features/RefreshTree.fs \
	Features/AddProjectItem.fs \
	Program.fs
do
	printf 'namespace Studio.FSharp\\n\\nmodule %s = let ready = true\\n' \
		"$(basename "${file%.fs}")" >"$fixture/src/Studio.FSharp/$file"
done

cat >"$fixture/src/Studio.VisualBasic/Studio.VisualBasic.vbproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <RootNamespace>Studio.VisualBasic</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../Studio.CSharp/Studio.CSharp.csproj" />
  </ItemGroup>
</Project>
EOF

for name in ExplorerPane ProjectRow SolutionRow; do
	printf 'Namespace Presentation\\n  Friend Class %s\\n  End Class\\nEnd Namespace\\n' "$name" \
		>"$fixture/src/Studio.VisualBasic/Presentation/$name.vb"
done
for name in CommandRouter TreeProjection WorkspaceSession; do
	printf 'Namespace Services\\n  Friend Class %s\\n  End Class\\nEnd Namespace\\n' "$name" \
		>"$fixture/src/Studio.VisualBasic/Services/$name.vb"
done
printf 'Friend Module Startup\\nEnd Module\\n' >"$fixture/src/Studio.VisualBasic/Startup.vb"

printf '%s\n' "$fixture/SemanticStudio.slnx"
