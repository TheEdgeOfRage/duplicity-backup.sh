# Maintainer: Yaron de Leeuw < me@jarondl.net >

# Maintained at : https://github.com/jarondl/aur-pkgbuilds-jarondl

pkgname=duplicity-backup
pkgver=1.7.1
pkgrel=1
pkgdesc="Bash wrapper script for automated backups with duplicity"
arch=('any')
url="https://github.com/TheEdgeOfRage/duplicity-backup"
license=('GPL3')
makedepends=('git')
depends=('duplicity')
optdepends=(
    'gnupg: encryption support'
    's3cmd: for storing on Amazon S3'
    'mailx: for mail notifications'
)
source=("https://github.com/TheEdgeOfRage/duplicity-backup.sh/archive/refs/tags/v${pkgver}.tar.gz")
md5sums=('SKIP')

package() {
    install -D -m644 "$pkgname.sh-${pkgver}/duplicity-backup.conf.example" "$pkgdir/usr/share/duplicity-backup.conf"
    install -D -m755 "$pkgname.sh-${pkgver}/duplicity-backup.sh" "$pkgdir/usr/bin/duplicity-backup"
}
