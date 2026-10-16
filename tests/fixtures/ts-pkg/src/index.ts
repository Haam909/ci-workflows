import ms from 'ms';

export function format(n: number): string {
  return ms(n);
}
