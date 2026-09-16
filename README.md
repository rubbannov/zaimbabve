## 🚀 Быстрый старт

Разворачивание готового (из репозитория GitHub) сайта Hugo, веб-сервера Nginx, SSL-сертификата Let's Encrypt и автодеплоя через GitHub Webhook выполняется одной командой:

```bash
curl -sSL https://raw.githubusercontent.com/rubbannov/zaimbabve/main/install.sh -o install.sh && bash install.sh
 ```

### 📋 Что понадобится во время установки:

1. Доменное имя (A-запись должна указывать на IP вашего VPS).
2. Email (для регистрации SSL-сертификата Let's Encrypt).
3. Webhook Secret (любая секретная строка для защиты вебхука).
4. Deploy Key:
- Скрипт сгенерирует SSH-ключ сервера и выведет его на экран.
-Добавьте этот ключ в GitHub: Репозиторий -> Settings -> Deploy keys -> Add deploy key.
- Нажмите Enter в консоли для продолжения установки.
