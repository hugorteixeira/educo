// Exemplo 20 – Braço Robótico MDF
// Apostila Eletrogate - KIT Robotica
#define potpin1 0
#define potpin2 1
#define potpin3 2
#define potpin4 3
#include <Servo.h>
Servo myservoBase; // Objeto servo para controlar a base
Servo myservoGarra; //Objeto servo para controlar a garra
Servo myservoAltura; //Objeto servo para controlar a altura do braço
Servo myservoProfundidade; //Objeto servo para profundidade a altura do braço
int val; // variable to read the value from the analog pin
void setup() {
myservoBase.attach(5); //Associa cada objeto a um pino pwm
myservoGarra.attach(6);
myservoAltura.attach(9);
myservoProfundidade.attach(10);
}
void loop() {
val = map(analogRead(potpin1), 0, 1023, 0, 179);
myservoBase.write(val);
val = map(analogRead(potpin2), 0, 1023, 0, 179);
myservoGarra.write(val);
val = map(analogRead(potpin3), 0, 1023, 0, 179);
myservoAltura.write(val);
val = map(analogRead(potpin4), 0, 1023, 0, 179);
myservoProfundidade.write(val);
}
