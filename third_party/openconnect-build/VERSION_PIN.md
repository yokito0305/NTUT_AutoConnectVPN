# Version Pin

- Canonical upstream: `https://gitlab.com/openconnect/openconnect`
- Maintained fork: `https://gitlab.com/yokito0305/openconnect.git`
- Submodule path: `third_party/openconnect`
- Pinned main-repo gitlink: `a7e751442e0e4bb8e3f18965960b1428e1a26bbc`

## Update Procedure

1. Update the fork branch in GitLab with the desired upstream rebase and patch.
2. In the main repository, update the submodule to the new fork commit.
3. Record the new gitlink here.
4. Re-run the Windows cross-build workflow.
5. Validate XML body capture before promoting the build.
