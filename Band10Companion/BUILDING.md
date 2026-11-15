# Сборка IPA через GitHub Actions

Workflow: `.github/workflows/band10-ipa.yml`.

После push в ветку `feature/band10-companion` workflow собирает приложение на macOS runner и публикует артефакт `Band10Companion-unsigned-ipa`.

Артефакт unsigned: его нужно подписать на iPhone через AltStore/SideStore либо подписать собственной Apple Developer Team. Сам факт успешной сборки не подтверждает Bluetooth-совместимость — это проверяется только на физическом Xiaomi Smart Band 10.

Если workflow не запускается, проверьте, что GitHub Actions разрешены в Settings → Actions для репозитория.
