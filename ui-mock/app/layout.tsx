import { Analytics } from '@vercel/analytics/next'
import type { Metadata, Viewport } from 'next'
import { M_PLUS_Rounded_1c, Noto_Sans_JP } from 'next/font/google'
import './globals.css'

const _notoSansJp = Noto_Sans_JP({
  subsets: ['latin'],
  weight: ['400', '500', '700'],
})

const _rounded = M_PLUS_Rounded_1c({
  subsets: ['latin'],
  weight: ['500', '700', '800'],
})

export const metadata: Metadata = {
  title: '顔かくし | 顔をかんたんに隠してSNSへ',
  description:
    '写真に写った顔を自動で見つけて、モザイク・ぼかし・スタンプでかんたんに隠せるアプリ。選択した写真は端末内で処理されます。',
  generator: 'v0.app',
  icons: {
    icon: [
      {
        url: '/icon-light-32x32.png',
        media: '(prefers-color-scheme: light)',
      },
      {
        url: '/icon-dark-32x32.png',
        media: '(prefers-color-scheme: dark)',
      },
      {
        url: '/icon.svg',
        type: 'image/svg+xml',
      },
    ],
    apple: '/apple-icon.png',
  },
}

export const viewport: Viewport = {
  colorScheme: 'light',
  themeColor: '#f4f8fb',
  width: 'device-width',
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="ja" className="light bg-background">
      <body className="antialiased">
        {children}
        {process.env.NODE_ENV === 'production' && <Analytics />}
      </body>
    </html>
  )
}
