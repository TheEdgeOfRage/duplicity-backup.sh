new_version=$1
if [ -z "$new_version" ]; then
    echo "Missing version parameter. Usage:" >&2
    echo "./bump_version x.x.x" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is dirty. Please commit or stash changes first." >&2
    exit 1
fi

echo Bumping to "$new_version"
sed -i -E "s/pkgver=[0-9]+\.[0-9]+\.[0-9]+/pkgver=${new_version}/" PKGBUILD
sed -i -E "s/DBSH_VERSION=\"v[0-9]+\.[0-9]+\.[0-9]+\"/DBSH_VERSION=\"v${new_version}\"/" duplicity-backup.sh

git add PKGBUILD duplicity-backup.sh
git commit -m "Bump to ${new_version}"
git push origin main
git tag "v${new_version}"
git push "v${new_version}"
